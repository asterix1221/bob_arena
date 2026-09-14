// protocol.cpp
// Реализация CRC32 (полином 0xEDB88320, стандартный для Ethernet/zlib/PNG).
#include "protocol.h"

static uint32_t crc32_table[256];
static bool crc32_table_ready = false;

static void build_crc32_table() {
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int j = 0; j < 8; ++j) {
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
    crc32_table_ready = true;
}

uint32_t crc32(const uint8_t* data, size_t length) {
    if (!crc32_table_ready) build_crc32_table();

    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; ++i) {
        crc = crc32_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}
