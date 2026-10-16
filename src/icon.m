// The game's own icon, read from the executable's resources when it runs (nothing is stored or shipped): the
// Dock shows it, and `sinking-star --extract-icon out.png sinking_star.exe` saves it for the app bundle.
#include "shim.h"
#import <Cocoa/Cocoa.h>

enum { RT_ICON_TYPE = 3, RT_GROUP_ICON_TYPE = 14 };

#pragma pack(push, 1)
typedef struct {
    uint16_t reserved, type, count;
} GroupIconDir;
typedef struct {
    uint8_t width, height, colors, reserved;
    uint16_t planes, bit_count;
    uint32_t bytes_in_resource;
    uint16_t id;
} GroupIconEntry;
typedef struct {
    uint8_t width, height, colors, reserved;
    uint16_t planes, bit_count;
    uint32_t bytes, offset;
} IcoEntry;
#pragma pack(pop)

typedef struct {
    uint32_t characteristics, timestamp;
    uint16_t major, minor, named_entries, id_entries;
} ResourceDirectory;
typedef struct {
    uint32_t name, offset;
} ResourceEntry;
typedef struct {
    uint32_t rva, size, code_page, reserved;
} ResourceData;

#define RESOURCE_SUBDIRECTORY 0x80000000u

static const uint8_t *resource_root(DWORD *size) {
    const uint8_t *nt = g_image_base + *(uint32_t *)(g_image_base + 0x3c);
    const uint32_t *dirs = (const uint32_t *)(nt + 24 + 112); // optional header's data directories (PE32+)
    *size = dirs[2 * 2 + 1];
    return dirs[2 * 2] ? g_image_base + dirs[2 * 2] : NULL;
}

// Finds a resource by type and id (id 0: the first one), in the first language.
static const uint8_t *find_resource(uint32_t type, uint32_t id, uint32_t *size) {
    DWORD root_size;
    const uint8_t *root = resource_root(&root_size);
    if (!root) return NULL;
    const uint8_t *dir = root;
    uint32_t keys[2] = {type, id};
    for (int level = 0; level < 3; level++) {
        const ResourceDirectory *d = (const void *)dir;
        const ResourceEntry *entries = (const void *)(d + 1);
        uint32_t count = d->named_entries + d->id_entries;
        const ResourceEntry *pick = NULL;
        for (uint32_t i = 0; i < count && !pick; i++) {
            bool match = level == 2 || (level == 1 && id == 0) || (entries[i].name == keys[level]);
            if (match || level == 2) pick = &entries[i];
        }
        if (!pick) return NULL;
        if (level == 2 || !(pick->offset & RESOURCE_SUBDIRECTORY)) {
            const ResourceData *data = (const void *)(root + (pick->offset & ~RESOURCE_SUBDIRECTORY));
            *size = data->size;
            return g_image_base + data->rva;
        }
        dir = root + (pick->offset & ~RESOURCE_SUBDIRECTORY);
    }
    return NULL;
}

// The largest icon of the executable's first icon group, as PNG or ICO data.
static NSData *largest_icon(void) {
    uint32_t group_size;
    const uint8_t *group = find_resource(RT_GROUP_ICON_TYPE, 0, &group_size);
    if (!group) return nil;
    const GroupIconDir *dir = (const void *)group;
    const GroupIconEntry *entries = (const void *)(dir + 1), *best = NULL;
    for (uint16_t i = 0; i < dir->count; i++)
        if (!best || (entries[i].width ?: 256) > (best->width ?: 256)) best = &entries[i]; // 0 means 256
    if (!best) return nil;
    uint32_t size;
    const uint8_t *data = find_resource(RT_ICON_TYPE, best->id, &size);
    if (!data) return nil;
    static const uint8_t png_signature[4] = {0x89, 'P', 'N', 'G'};
    if (size > 4 && !memcmp(data, png_signature, 4)) return [NSData dataWithBytes:data length:size];

    // A bitmap icon: wrap it in a one-image ICO file for ImageIO to decode.
    NSMutableData *ico = [NSMutableData data];
    GroupIconDir header = {0, 1, 1};
    IcoEntry entry = {best->width,  best->height,    best->colors, 0,
                      best->planes, best->bit_count, size,         sizeof header + sizeof entry};
    [ico appendBytes:&header length:sizeof header];
    [ico appendBytes:&entry length:sizeof entry];
    [ico appendBytes:data length:size];
    return ico;
}

void icon_apply(void) {
    @autoreleasepool {
        NSData *data = largest_icon();
        NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
        if (image) NSApp.applicationIconImage = image;
    }
}

bool icon_write_png(const char *path) {
    @autoreleasepool {
        NSData *data = largest_icon();
        NSBitmapImageRep *rep = data ? [NSBitmapImageRep imageRepWithData:data] : nil;
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return png && [png writeToFile:@(path) atomically:YES];
    }
}
