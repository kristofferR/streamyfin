#include "file_identity.h"

#include <cstdlib>
#include <iostream>

static void check(bool condition, const char *message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::abort();
    }
}

static int64_t command_result(int status, int64_t id) {
    mpv_node value = {};
    value.format = MPV_FORMAT_INT64;
    value.u.int64 = id;
    char key[] = "playlist_entry_id";
    char *keys[] = {key};
    mpv_node_list map = {};
    map.num = 1;
    map.keys = keys;
    map.values = &value;
    mpv_node result = {};
    result.format = MPV_FORMAT_NODE_MAP;
    result.u.list = &map;
    return load_file_entry_id(status, result);
}

int main() {
    const int64_t large_id = INT64_C(1) << 40;
    check(command_result(0, large_id) == large_id, "command result keeps all 64 bits");
    check(command_result(MPV_ERROR_COMMAND, large_id) == -1, "rejected command has no identity");
    check(command_result(0, -1) == -1, "invalid negative ID is not accepted");
    mpv_node absent = {};
    check(load_file_entry_id(0, absent) == -1, "missing result cannot borrow a current playlist ID");
    absent.format = MPV_FORMAT_NODE_MAP;
    check(load_file_entry_id(0, absent) == -1, "missing map is unknown");

    EventFileIdentity events;
    check(events.current() == -1, "no identity before a start");
    // Two accepted commands, but the first is cancelled before it starts.
    const int64_t cancelled = command_result(0, 11);
    const int64_t replacement = command_result(0, 12);
    events.start(replacement);
    check(events.current() == replacement && events.current() != cancelled,
          "a skipped request consumes no imaginary start event");
    check(command_result(MPV_ERROR_COMMAND, 13) == -1 && events.current() == 12,
          "command rejection cannot rebind the previous file");

    // Several starts can already be queued before the first command returns.
    events.start(20);
    const int64_t immutable_property_id = events.current();
    events.end(20);
    events.start(21);
    events.end(21);
    events.start(22);
    check(immutable_property_id == 20 && events.current() == 22,
          "later queued starts do not relabel an earlier property snapshot");
    check(command_result(0, 22) == events.current(), "early start matches a later result by ID");

    events.end(21);
    check(events.current() == 22, "an unrelated end cannot clear the active file");
    events.end(22);
    check(events.current() == -1, "properties after end have no file identity");
    events.start(30);
    events.clear();
    check(events.current() == -1, "shutdown or overflow invalidates receipt stamping");
    events.start(31);
    check(events.current() == 31, "a later explicit start recovers identity without FIFO state");
    events.start(-1);
    check(events.current() == -1, "malformed start fails closed");
    std::cout << "Native file identity scenarios passed\n";
}
