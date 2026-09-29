// SPDX-License-Identifier: GPL-2.0
/*
 * QDC507 DATA11 用户态桥。
 *
 * 该模块只连接 USB AT 原本使用的 DATA11 SMD 流通道，并通过
 * /dev/djonehub_data11 暴露给用户态。它不会访问原厂服务使用的 DATA1，
 * 因此无需停止 ql_manager_server，也不会主动修改模块的网络配置。
 */

#include <linux/atomic.h>
#include <linux/completion.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/poll.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>
#include <linux/wait.h>

#include <soc/qcom/smd.h>

#define DJONEHUB_DEVICE_NAME "djonehub_data11"
#define DJONEHUB_SMD_CHANNEL "DATA11"
#define DJONEHUB_MAX_IO_SIZE 4096U

struct djonehub_bridge {
	smd_channel_t *channel;
	spinlock_t state_lock;
	struct mutex read_lock;
	struct mutex write_lock;
	wait_queue_head_t read_wait;
	wait_queue_head_t write_wait;
	struct completion close_done;
	atomic_t users;
	bool remote_open;
	bool disconnected;
	bool closing;
};

static struct djonehub_bridge bridge;

/* 回调可能在中断上下文执行，因此这里只更新状态并唤醒等待者。 */
static void djonehub_smd_notify(void *priv, unsigned int event)
{
	struct djonehub_bridge *dev = priv;
	unsigned long flags;
	bool wake_read = false;
	bool wake_write = false;

	spin_lock_irqsave(&dev->state_lock, flags);
	switch (event) {
	case SMD_EVENT_OPEN:
		dev->remote_open = true;
		dev->disconnected = false;
		wake_read = true;
		wake_write = true;
		break;
	case SMD_EVENT_CLOSE:
		dev->remote_open = false;
		dev->disconnected = true;
		wake_read = true;
		wake_write = true;
		if (dev->closing)
			complete_all(&dev->close_done);
		break;
	case SMD_EVENT_REOPEN_READY:
		dev->remote_open = false;
		dev->disconnected = true;
		wake_read = true;
		wake_write = true;
		complete_all(&dev->close_done);
		break;
	case SMD_EVENT_DATA:
		wake_read = true;
		wake_write = true;
		break;
	default:
		break;
	}
	spin_unlock_irqrestore(&dev->state_lock, flags);

	if (wake_read)
		wake_up_interruptible(&dev->read_wait);
	if (wake_write)
		wake_up_interruptible(&dev->write_wait);
}

/* wait_event 的条件函数；返回 true 表示有数据或连接状态已发生变化。 */
static bool djonehub_read_ready(struct djonehub_bridge *dev)
{
	unsigned long flags;
	bool ready;

	spin_lock_irqsave(&dev->state_lock, flags);
	ready = dev->closing || dev->disconnected ||
		(dev->remote_open && dev->channel &&
		 smd_read_avail(dev->channel) > 0);
	spin_unlock_irqrestore(&dev->state_lock, flags);

	return ready;
}

/* wait_event 的条件函数；返回 true 表示可写或连接状态已发生变化。 */
static bool djonehub_write_ready(struct djonehub_bridge *dev)
{
	unsigned long flags;
	bool ready;

	spin_lock_irqsave(&dev->state_lock, flags);
	ready = dev->closing || dev->disconnected ||
		(dev->remote_open && dev->channel &&
		 smd_write_avail(dev->channel) > 0);
	spin_unlock_irqrestore(&dev->state_lock, flags);

	return ready;
}

static int djonehub_open(struct inode *inode, struct file *file)
{
	unsigned long flags;
	int ret;

	/* DATA11 是单一 AT 字节流，多客户端并发会互相截断响应。 */
	if (atomic_cmpxchg(&bridge.users, 0, 1) != 0)
		return -EBUSY;

	spin_lock_irqsave(&bridge.state_lock, flags);
	bridge.remote_open = false;
	bridge.disconnected = false;
	bridge.closing = false;
	bridge.channel = NULL;
	reinit_completion(&bridge.close_done);
	spin_unlock_irqrestore(&bridge.state_lock, flags);

	ret = smd_named_open_on_edge(DJONEHUB_SMD_CHANNEL, SMD_APPS_MODEM,
				     &bridge.channel, &bridge,
				     djonehub_smd_notify);
	if (ret) {
		spin_lock_irqsave(&bridge.state_lock, flags);
		bridge.channel = NULL;
		bridge.disconnected = true;
		spin_unlock_irqrestore(&bridge.state_lock, flags);
		atomic_set(&bridge.users, 0);
		return ret;
	}

	file->private_data = &bridge;
	return nonseekable_open(inode, file);
}

static int djonehub_release(struct inode *inode, struct file *file)
{
	struct djonehub_bridge *dev = file->private_data;
	unsigned long flags;
	bool wait_for_close;
	smd_channel_t *channel;

	spin_lock_irqsave(&dev->state_lock, flags);
	dev->closing = true;
	wait_for_close = dev->remote_open;
	channel = dev->channel;
	spin_unlock_irqrestore(&dev->state_lock, flags);

	wake_up_interruptible(&dev->read_wait);
	wake_up_interruptible(&dev->write_wait);

	if (channel) {
		smd_close(channel);
		/*
		 * 远端已打开时，必须等待 SMD 完成关闭确认。否则用户紧接着
		 * rmmod，旧回调仍可能落到已经卸载的模块代码中。
		 */
		if (wait_for_close)
			wait_for_completion(&dev->close_done);
	}

	spin_lock_irqsave(&dev->state_lock, flags);
	dev->channel = NULL;
	dev->remote_open = false;
	dev->disconnected = true;
	spin_unlock_irqrestore(&dev->state_lock, flags);

	atomic_set(&dev->users, 0);
	return 0;
}

static ssize_t djonehub_read(struct file *file, char __user *user_buffer,
			     size_t count, loff_t *position)
{
	struct djonehub_bridge *dev = file->private_data;
	unsigned long flags;
	unsigned char *buffer;
	size_t wanted;
	loff_t copy_position = 0;
	int available;
	int ret;

	if (!count)
		return 0;

	wanted = min_t(size_t, count, DJONEHUB_MAX_IO_SIZE);
	buffer = kmalloc(wanted, GFP_KERNEL);
	if (!buffer)
		return -ENOMEM;

	ret = mutex_lock_interruptible(&dev->read_lock);
	if (ret)
		goto out_free;

	for (;;) {
		spin_lock_irqsave(&dev->state_lock, flags);
		if (dev->closing || dev->disconnected || !dev->channel) {
			spin_unlock_irqrestore(&dev->state_lock, flags);
			ret = -EPIPE;
			goto out_unlock;
		}
		available = dev->remote_open ? smd_read_avail(dev->channel) : 0;
		spin_unlock_irqrestore(&dev->state_lock, flags);

		if (available > 0)
			break;
		if (file->f_flags & O_NONBLOCK) {
			ret = -EAGAIN;
			goto out_unlock;
		}

		ret = wait_event_interruptible(dev->read_wait,
					       djonehub_read_ready(dev));
		if (ret)
			goto out_unlock;
	}

	available = min_t(int, available, wanted);
	ret = smd_read(dev->channel, buffer, available);
	/* 使用实机内核已导出的辅助函数，兼容厂商裁剪后的 ARM 导出表。 */
	if (ret > 0)
		ret = simple_read_from_buffer(user_buffer, ret, &copy_position,
					      buffer, ret);

out_unlock:
	mutex_unlock(&dev->read_lock);
out_free:
	kfree(buffer);
	return ret;
}

static ssize_t djonehub_write(struct file *file,
			      const char __user *user_buffer, size_t count,
			      loff_t *position)
{
	struct djonehub_bridge *dev = file->private_data;
	unsigned long flags;
	unsigned char *buffer;
	size_t wanted;
	size_t written = 0;
	int available;
	int chunk;
	int ret;

	if (!count)
		return 0;

	/* 限制单次分配，避免错误客户端耗尽模块上的小内存。 */
	wanted = min_t(size_t, count, DJONEHUB_MAX_IO_SIZE);
	buffer = memdup_user(user_buffer, wanted);
	if (IS_ERR(buffer))
		return PTR_ERR(buffer);

	ret = mutex_lock_interruptible(&dev->write_lock);
	if (ret)
		goto out_free;

	while (written < wanted) {
		spin_lock_irqsave(&dev->state_lock, flags);
		if (dev->closing || dev->disconnected || !dev->channel) {
			spin_unlock_irqrestore(&dev->state_lock, flags);
			ret = written ? written : -EPIPE;
			goto out_unlock;
		}
		available = dev->remote_open ? smd_write_avail(dev->channel) : 0;
		spin_unlock_irqrestore(&dev->state_lock, flags);

		if (available <= 0) {
			if (file->f_flags & O_NONBLOCK) {
				ret = written ? written : -EAGAIN;
				goto out_unlock;
			}
			if (dev->channel)
				smd_enable_read_intr(dev->channel);
			ret = wait_event_interruptible(dev->write_wait,
						       djonehub_write_ready(dev));
			if (ret) {
				ret = written ? written : ret;
				goto out_unlock;
			}
			continue;
		}

		smd_disable_read_intr(dev->channel);
		chunk = min_t(size_t, available, wanted - written);
		ret = smd_write(dev->channel, buffer + written, chunk);
		if (ret < 0) {
			ret = written ? written : ret;
			goto out_unlock;
		}
		if (!ret) {
			ret = written ? written : -EIO;
			goto out_unlock;
		}
		written += ret;
	}

	ret = written;

out_unlock:
	mutex_unlock(&dev->write_lock);
out_free:
	kfree(buffer);
	return ret;
}

static unsigned int djonehub_poll(struct file *file, poll_table *wait)
{
	struct djonehub_bridge *dev = file->private_data;
	unsigned long flags;
	unsigned int mask = 0;

	poll_wait(file, &dev->read_wait, wait);
	poll_wait(file, &dev->write_wait, wait);

	spin_lock_irqsave(&dev->state_lock, flags);
	if (dev->closing || dev->disconnected || !dev->channel) {
		mask = POLLERR | POLLHUP;
	} else if (dev->remote_open) {
		if (smd_read_avail(dev->channel) > 0)
			mask |= POLLIN | POLLRDNORM;
		if (smd_write_avail(dev->channel) > 0)
			mask |= POLLOUT | POLLWRNORM;
	}
	spin_unlock_irqrestore(&dev->state_lock, flags);

	return mask;
}

static const struct file_operations djonehub_fops = {
	.owner = THIS_MODULE,
	.open = djonehub_open,
	.release = djonehub_release,
	.read = djonehub_read,
	.write = djonehub_write,
	.poll = djonehub_poll,
	.llseek = no_llseek,
};

static struct miscdevice djonehub_misc_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = DJONEHUB_DEVICE_NAME,
	.fops = &djonehub_fops,
	.mode = 0600,
};

static int __init djonehub_init(void)
{
	int ret;

	spin_lock_init(&bridge.state_lock);
	mutex_init(&bridge.read_lock);
	mutex_init(&bridge.write_lock);
	init_waitqueue_head(&bridge.read_wait);
	init_waitqueue_head(&bridge.write_wait);
	init_completion(&bridge.close_done);
	atomic_set(&bridge.users, 0);
	bridge.disconnected = true;

	ret = misc_register(&djonehub_misc_device);
	if (ret)
		pr_err("djonehub_data11: 注册字符设备失败: %d\n", ret);
	else
		pr_info("djonehub_data11: 已注册 /dev/%s，目标通道 %s\n",
			DJONEHUB_DEVICE_NAME, DJONEHUB_SMD_CHANNEL);

	return ret;
}

static void __exit djonehub_exit(void)
{
	misc_deregister(&djonehub_misc_device);
	pr_info("djonehub_data11: 字符设备已注销\n");
}

module_init(djonehub_init);
module_exit(djonehub_exit);

MODULE_DESCRIPTION("DJOneHub QDC507 DATA11 SMD 用户态桥");
MODULE_AUTHOR("DJOneHub");
MODULE_LICENSE("GPL v2");
