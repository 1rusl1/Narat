"""Read dimensions and MIME from the catalogue's supported raster headers."""

import struct


def _jpeg_size(raw):
    offset = 2
    frame_markers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                     0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while offset < len(raw) and raw[offset] == 0xFF:
        while offset < len(raw) and raw[offset] == 0xFF:
            offset += 1
        if offset >= len(raw):
            break
        marker = raw[offset]
        offset += 1
        if marker in (0xDA, 0xD9):
            break
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(raw):
            break
        length = struct.unpack_from(">H", raw, offset)[0]
        if length < 2 or offset + length > len(raw):
            break
        if marker in frame_markers and length >= 8:
            height, width = struct.unpack_from(">HH", raw, offset + 3)
            return width, height
        offset += length
    raise ValueError("JPEG has no readable frame header")


def _webp_size(raw):
    end = struct.unpack_from("<I", raw, 4)[0] + 8
    if end > len(raw):
        raise ValueError("Truncated WebP container")
    offset = 12
    while offset + 8 <= end:
        name = raw[offset:offset + 4]
        size = struct.unpack_from("<I", raw, offset + 4)[0]
        start = offset + 8
        if start + size > end:
            break
        data = raw[start:start + min(size, 10)]
        if name == b"VP8X" and size == 10:
            return (1 + int.from_bytes(data[4:7], "little"),
                    1 + int.from_bytes(data[7:10], "little"))
        if name == b"VP8L" and len(data) >= 5 and data[0] == 0x2F:
            bits = int.from_bytes(data[1:5], "little")
            return 1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF)
        if name == b"VP8 " and len(data) == 10 and not data[0] & 1 and data[3:6] == b"\x9d\x01\x2a":
            width, height = struct.unpack_from("<HH", data, 6)
            return width & 0x3FFF, height & 0x3FFF
        offset = start + size + (size & 1)
    raise ValueError("WebP has no readable image header")


def parse_image_dimensions_and_mime(raw):
    if (raw.startswith(b"\x89PNG\r\n\x1a\n") and len(raw) >= 33
            and raw[8:16] == b"\x00\x00\x00\x0dIHDR"):
        width, height = struct.unpack_from(">II", raw, 16)
        mime = "image/png"
    elif raw.startswith(b"\xff\xd8"):
        width, height = _jpeg_size(raw)
        mime = "image/jpeg"
    elif len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        width, height = _webp_size(raw)
        mime = "image/webp"
    else:
        raise ValueError("Unsupported or corrupt image header")
    if not width or not height:
        raise ValueError("Image width and height must be positive")
    return width, height, mime
