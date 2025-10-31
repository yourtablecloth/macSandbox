#!/bin/bash

# Xcode 프로젝트 생성 및 entitlement 설정 스크립트

set -e

echo "🔧 Xcode 프로젝트 생성 중..."

# Swift Package를 Xcode 프로젝트로 변환
swift package generate-xcodeproj

PROJECT_NAME="macosdownloader"
XCODEPROJ="${PROJECT_NAME}.xcodeproj"
ENTITLEMENTS_FILE="${PROJECT_NAME}.entitlements"

if [ ! -f "$XCODEPROJ/project.pbxproj" ]; then
    echo "❌ Xcode 프로젝트 생성 실패"
    exit 1
fi

echo "✅ Xcode 프로젝트 생성 완료"
echo ""
echo "⚠️  다음 단계를 수동으로 수행해야 합니다:"
echo ""
echo "1. Xcode에서 ${XCODEPROJ}를 엽니다:"
echo "   open ${XCODEPROJ}"
echo ""
echo "2. 프로젝트 설정에서:"
echo "   - Target '${PROJECT_NAME}' 선택"
echo "   - 'Signing & Capabilities' 탭으로 이동"
echo "   - '+ Capability' 버튼 클릭"
echo "   - 'App Sandbox' 추가"
echo "   - 'Network' → 'Outgoing Connections (Client)' 체크"
echo "   - 'File Access' → 'User Selected File' → 'Read/Write' 체크"
echo ""
echo "3. 또는 Build Settings에서:"
echo "   - 'Code Signing Entitlements'에 '${ENTITLEMENTS_FILE}' 경로 설정"
echo ""
echo "4. Xcode에서 빌드 (⌘+B)"
echo ""
echo "📝 참고: Virtualization framework는 서명된 앱에서만 작동합니다."
