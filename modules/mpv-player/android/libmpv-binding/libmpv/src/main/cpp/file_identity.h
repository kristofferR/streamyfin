#pragma once

#include <cstdint>
#include <cstring>
#include <mpv/client.h>

// Read only the loadfile command's own result, never a later playlist property.
inline int64_t load_file_entry_id(int status, const mpv_node &result) {
    if (status < 0 || result.format != MPV_FORMAT_NODE_MAP || !result.u.list)
        return -1;
    const mpv_node_list &map = *result.u.list;
    if (!map.keys || !map.values)
        return -1;
    for (int i = 0; i < map.num; ++i) {
        if (map.keys[i] && std::strcmp(map.keys[i], "playlist_entry_id") == 0) {
            const mpv_node &value = map.values[i];
            return value.format == MPV_FORMAT_INT64 && value.u.int64 >= 0
                ? value.u.int64 : -1;
        }
    }
    return -1;
}

// Owned only by the native event thread. No correspondence between load
// requests and start events is assumed: cancelled requests need not start.
class EventFileIdentity {
public:
    void start(int64_t entry_id) { active_ = entry_id >= 0 ? entry_id : -1; }
    void end(int64_t entry_id) {
        if (entry_id < 0 || entry_id == active_)
            clear();
    }
    void clear() { active_ = -1; }
    int64_t current() const { return active_; }

private:
    int64_t active_ = -1;
};

// Copy before the next mpv_wait_event invalidates the C payload.
struct EndFileSnapshot {
    int64_t entry_id;
    int reason;
    int error;
    int64_t insert_id;
    int insert_count;
};

inline EndFileSnapshot copy_end_file(const mpv_event_end_file *end) {
    if (!end)
        return {-1, -1, 0, 0, 0};
    return {end->playlist_entry_id, static_cast<int>(end->reason), end->error,
            end->playlist_insert_id, end->playlist_insert_num_entries};
}
