// 只读扫描指定 USB 设备的全部接口、备用设置和端点。
// 本工具不会 claim 接口、不会发送控制请求，也不会修改设备状态。
#include <libusb-1.0/libusb.h>

#include <stdio.h>
#include <stdlib.h>

static const char *transfer_type_name(uint8_t attributes) {
    switch (attributes & LIBUSB_TRANSFER_TYPE_MASK) {
        case LIBUSB_TRANSFER_TYPE_CONTROL: return "control";
        case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: return "isochronous";
        case LIBUSB_TRANSFER_TYPE_BULK: return "bulk";
        case LIBUSB_TRANSFER_TYPE_INTERRUPT: return "interrupt";
        default: return "unknown";
    }
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "用法: %s <vid-hex> <pid-hex>\n", argv[0]);
        return 2;
    }

    const long wanted_vid = strtol(argv[1], NULL, 16);
    const long wanted_pid = strtol(argv[2], NULL, 16);
    libusb_context *context = NULL;
    libusb_device **devices = NULL;

    int result = libusb_init(&context);
    if (result != LIBUSB_SUCCESS) {
        fprintf(stderr, "libusb_init 失败: %s\n", libusb_error_name(result));
        return 1;
    }

    const ssize_t count = libusb_get_device_list(context, &devices);
    if (count < 0) {
        fprintf(stderr, "读取 USB 设备列表失败: %s\n", libusb_error_name((int)count));
        libusb_exit(context);
        return 1;
    }

    int found = 0;
    for (ssize_t device_index = 0; device_index < count; ++device_index) {
        libusb_device *device = devices[device_index];
        struct libusb_device_descriptor device_descriptor;
        if (libusb_get_device_descriptor(device, &device_descriptor) != LIBUSB_SUCCESS ||
            device_descriptor.idVendor != wanted_vid ||
            device_descriptor.idProduct != wanted_pid) {
            continue;
        }

        found = 1;
        printf("设备 %04x:%04x bus=%u address=%u configurations=%u\n",
               device_descriptor.idVendor, device_descriptor.idProduct,
               libusb_get_bus_number(device), libusb_get_device_address(device),
               device_descriptor.bNumConfigurations);

        for (uint8_t config_index = 0;
             config_index < device_descriptor.bNumConfigurations;
             ++config_index) {
            struct libusb_config_descriptor *config = NULL;
            result = libusb_get_config_descriptor(device, config_index, &config);
            if (result != LIBUSB_SUCCESS) {
                fprintf(stderr, "读取配置 %u 失败: %s\n", config_index,
                        libusb_error_name(result));
                continue;
            }

            printf("配置 index=%u value=%u interfaces=%u\n", config_index,
                   config->bConfigurationValue, config->bNumInterfaces);
            for (uint8_t interface_index = 0;
                 interface_index < config->bNumInterfaces;
                 ++interface_index) {
                const struct libusb_interface *interface = &config->interface[interface_index];
                for (int alt_index = 0; alt_index < interface->num_altsetting; ++alt_index) {
                    const struct libusb_interface_descriptor *alt = &interface->altsetting[alt_index];
                    printf("  interface=%u alt=%u class=%u subclass=%u protocol=%u endpoints=%u\n",
                           alt->bInterfaceNumber, alt->bAlternateSetting,
                           alt->bInterfaceClass, alt->bInterfaceSubClass,
                           alt->bInterfaceProtocol, alt->bNumEndpoints);
                    for (uint8_t endpoint_index = 0;
                         endpoint_index < alt->bNumEndpoints;
                         ++endpoint_index) {
                        const struct libusb_endpoint_descriptor *endpoint =
                            &alt->endpoint[endpoint_index];
                        printf("    endpoint=0x%02x direction=%s type=%s max_packet=%u interval=%u\n",
                               endpoint->bEndpointAddress,
                               (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) ==
                                       LIBUSB_ENDPOINT_IN ? "IN" : "OUT",
                               transfer_type_name(endpoint->bmAttributes),
                               endpoint->wMaxPacketSize, endpoint->bInterval);
                    }
                }
            }
            libusb_free_config_descriptor(config);
        }
    }

    libusb_free_device_list(devices, 1);
    libusb_exit(context);
    if (!found) {
        fprintf(stderr, "未发现设备 %04lx:%04lx\n", wanted_vid, wanted_pid);
        return 3;
    }
    return 0;
}
