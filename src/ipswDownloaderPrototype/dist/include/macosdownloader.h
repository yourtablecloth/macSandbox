#ifndef MACOSDOWNLOADER_H
#define MACOSDOWNLOADER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - 함수

/// 최신 macOS 복구 이미지 가져오기
/// @param outVersion 버전 문자열 포인터의 포인터 (예: "15.0.1")
/// @param outBuild 빌드 문자열 포인터의 포인터 (예: "25A362")
/// @param outURL URL 문자열 포인터의 포인터
/// @param outSize 파일 크기 포인터 (바이트)
/// @return 0 = 성공, -1 = 지원되지 않는 버전, -2 = 오류
int32_t macosdownloader_get_latest_image(
    char** outVersion,
    char** outBuild,
    char** outURL,
    int64_t* outSize
);

/// 현재 시스템 정보 가져오기
/// @param outModel 모델 식별자 문자열 포인터의 포인터 (예: "Mac14,2")
/// @param outArch 아키텍처 문자열 포인터의 포인터 (예: "arm64")
/// @param outBoard 보드 ID 문자열 포인터의 포인터
/// @return 0 = 성공, -2 = 오류
int32_t macosdownloader_get_system_info(
    char** outModel,
    char** outArch,
    char** outBoard
);

/// 문자열 메모리 해제
/// @param str 해제할 문자열 포인터
void macosdownloader_free_string(char* str);

/// 라이브러리 버전 가져오기
/// @return 버전 문자열 (호출자가 macosdownloader_free_string으로 해제해야 함)
char* macosdownloader_get_version(void);

/// IPSW 이미지 다운로드
/// @param url 다운로드 URL
/// @param outputPath 저장 경로
/// @return 0 = 성공, -2 = 오류
int32_t macosdownloader_download(
    const char* url,
    const char* outputPath
);

#ifdef __cplusplus
}
#endif

#endif // MACOSDOWNLOADER_H
