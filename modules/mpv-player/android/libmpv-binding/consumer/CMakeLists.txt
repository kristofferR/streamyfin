cmake_minimum_required(VERSION 3.22.1)
project(streamyfin_mpv_binding LANGUAGES CXX)

if(NOT RELEASED_MEDIA_ROOT)
    message(FATAL_ERROR "RELEASED_MEDIA_ROOT must name verified released native inputs")
endif()
if(NOT ANDROID_STL STREQUAL "none")
    message(FATAL_ERROR "Disable automatic STL linking; use the verified released runtime")
endif()

# NDK 29's 'none' adds -nostdinc++/-nostdlib++. Restore only its headers;
# the imported target supplies the exact runtime used for linking and packaging.
set(CXX_HEADERS "${CMAKE_SYSROOT}/usr/include/c++/v1")
if(NOT EXISTS "${CXX_HEADERS}/mutex" OR NOT EXISTS "${CXX_HEADERS}/atomic")
    message(FATAL_ERROR "Expected the pinned NDK libc++ headers at ${CXX_HEADERS}")
endif()
add_library(released_cxx SHARED IMPORTED)
set_target_properties(released_cxx PROPERTIES
    IMPORTED_LOCATION "${RELEASED_MEDIA_ROOT}/cmake/${ANDROID_ABI}/libc++_shared.so"
    IMPORTED_SONAME "libc++_shared.so")
target_include_directories(released_cxx SYSTEM INTERFACE "${CXX_HEADERS}")

set(BINDING_CPP "${CMAKE_CURRENT_LIST_DIR}/../libmpv/src/main/cpp")
add_library(player SHARED
    "${BINDING_CPP}/main.cpp" "${BINDING_CPP}/render.cpp"
    "${BINDING_CPP}/log.cpp" "${BINDING_CPP}/jni_utils.cpp"
    "${BINDING_CPP}/property.cpp" "${BINDING_CPP}/event.cpp")
target_include_directories(player PRIVATE "${CMAKE_CURRENT_LIST_DIR}/headers")

# AGP packages imported libraries. Keep them out of jniLibs to avoid duplicates.
add_library(mpv SHARED IMPORTED)
set_target_properties(mpv PROPERTIES IMPORTED_LOCATION
    "${RELEASED_MEDIA_ROOT}/cmake/${ANDROID_ABI}/libmpv.so")
add_library(avcodec SHARED IMPORTED)
set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION
    "${RELEASED_MEDIA_ROOT}/cmake/${ANDROID_ABI}/libavcodec.so")
target_link_libraries(player PRIVATE mpv avcodec released_cxx log)
target_link_options(player PRIVATE "-Wl,--no-undefined")
