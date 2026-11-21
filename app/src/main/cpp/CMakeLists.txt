cmake_minimum_required(VERSION 3.22.1)
project(qcwhisper C CXX)

# Whisper at -O0 is unusably slow, and the app only ships debug builds, so always optimize.
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)

# whisper.cpp v1.9.5, pinned to the commit so the build can't drift.
include(FetchContent)
FetchContent_Declare(
    whisper
    GIT_REPOSITORY https://github.com/ggml-org/whisper.cpp.git
    GIT_TAG        d1be6fde11ac6e0407606b4e42fe72d34add8037
    GIT_SHALLOW    FALSE
)

set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(WHISPER_ALL_WARNINGS   OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP            OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE            OFF CACHE BOOL "" FORCE)
# Quest 3 / 3S (XR2 Gen 2) cores all support dotprod and fp16.
set(GGML_CPU_ARM_ARCH "armv8.2-a+dotprod+fp16" CACHE STRING "" FORCE)
FetchContent_MakeAvailable(whisper)

add_library(qcwhisper SHARED qcwhisper.c)
target_link_libraries(qcwhisper PRIVATE whisper log)
