cmake_minimum_required(VERSION 3.16)
project(push_encoder)

set(CMAKE_CXX_STANDARD 17)

add_library(push_encoder SHARED push_encoder.cpp)

find_library(ace_napi_lib ace_napi.z)
find_library(media_venc_lib native_media_venc)
find_library(media_aenc_lib native_media_aenc)
find_library(media_acodec_lib native_media_acodec)
find_library(media_core_lib native_media_core)
find_library(media_codecbase_lib native_media_codecbase)
find_library(native_window_lib native_window)
find_library(hilog_lib hilog_ndk.z)

target_link_libraries(push_encoder PUBLIC
    ${ace_napi_lib}
    ${media_venc_lib}
    ${media_aenc_lib}
    ${media_acodec_lib}
    ${media_core_lib}
    ${media_codecbase_lib}
    ${native_window_lib}
    ${hilog_lib}
)
