#include <stdio.h>
#include <stdlib.h>
#include "dist/include/macosdownloader.h"

int main() {
    printf("🍎 macOS Downloader C Library Test\n");
    printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n");
    
    // 1. 라이브러리 버전 확인
    char* version = macosdownloader_get_version();
    if (version) {
        printf("📦 라이브러리 버전: %s\n\n", version);
        macosdownloader_free_string(version);
    }
    
    // 2. 시스템 정보 가져오기
    printf("🖥️  시스템 정보:\n");
    char *model = NULL, *arch = NULL, *board = NULL;
    int32_t result = macosdownloader_get_system_info(&model, &arch, &board);
    
    if (result == 0) {
        printf("   모델: %s\n", model ? model : "Unknown");
        printf("   아키텍처: %s\n", arch ? arch : "Unknown");
        printf("   보드 ID: %s\n\n", board ? board : "Unknown");
        
        macosdownloader_free_string(model);
        macosdownloader_free_string(arch);
        macosdownloader_free_string(board);
    } else {
        printf("   ❌ 시스템 정보 가져오기 실패 (코드: %d)\n\n", result);
    }
    
    // 3. 최신 macOS 복구 이미지 가져오기
    printf("🔍 최신 macOS 복구 이미지 가져오기...\n");
    char *imgVersion = NULL, *imgBuild = NULL, *imgURL = NULL;
    int64_t imgSize = 0;
    
    result = macosdownloader_get_latest_image(&imgVersion, &imgBuild, &imgURL, &imgSize);
    
    if (result == 0) {
        printf("   ✅ 성공!\n");
        printf("   버전: %s\n", imgVersion ? imgVersion : "Unknown");
        printf("   빌드: %s\n", imgBuild ? imgBuild : "Unknown");
        printf("   URL: %s\n", imgURL ? imgURL : "Unknown");
        printf("   크기: %lld bytes\n", imgSize);
        
        macosdownloader_free_string(imgVersion);
        macosdownloader_free_string(imgBuild);
        macosdownloader_free_string(imgURL);
    } else if (result == -1) {
        printf("   ⚠️  지원되지 않는 macOS 버전\n");
    } else {
        printf("   ❌ 이미지 가져오기 실패 (코드: %d)\n", result);
    }
    
    printf("\n🎉 테스트 완료!\n");
    return 0;
}
