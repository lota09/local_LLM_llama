import pygame
import sys
import random
from collections import deque

# --- 설정 상수 ---
SCREEN_WIDTH = 800
SCREEN_HEIGHT = 600
FPS = 60

class Game:
    def __init__(self):
        pygame.init() # Pygame 초기화
        
        self.screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
        pygame.display.set_caption("🐱 Cat Mario")
        
        self.clock = pygame.time.Clock()
        self.font = pygame.font.Font(None, 36) # 폰트 생성
        
        # 색상 정의
        self.colors = {
            "bg": (176, 255, 255),       # 하늘색 배경
            "cat_body": "#FF9EAA",      # 핑크빛 고양이 몸체 색상을 Hex로 변환 필요 시 사용 가능
            "platform_top": "#FFE4B5"   # 플랫폼 색상 (황금색 계열)
        }
        
        self.game_over_flag = False
    
    def run(self):
        while not self.game_over_flag: # 게임 루프 시작
            
            for event in pygame.event.get():
                if event.type == pygame.QUIT: # 창 닫기 이벤트 처리
                
                    return
            
            self.update() # 업데이트 로직 호출
            self.draw() # 그리드 시스템 및 시각적 요소 렌더링
            
            self.clock.tick(FPS) # FPS 제한 적용 - 60fps 유지
            
            pygame.display.flip() # 화면 갱신 (flip)


# 메인 진입점 정의 및 실행 조건 작성 완료!

if __name__ == "__main__":
    game_instance = Game() # 인스턴스 생성 및 실행됨!