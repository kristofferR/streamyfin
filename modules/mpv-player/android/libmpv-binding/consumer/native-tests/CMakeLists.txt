cmake_minimum_required(VERSION 3.22.1)
project(binding_identity_tests LANGUAGES CXX)
enable_testing()

add_executable(file_identity_test ../../libmpv/src/test/cpp/file_identity_test.cpp)
target_compile_features(file_identity_test PRIVATE cxx_std_11)
target_include_directories(file_identity_test PRIVATE
    ../headers ../../libmpv/src/main/cpp)
add_test(NAME file_identity COMMAND file_identity_test)
