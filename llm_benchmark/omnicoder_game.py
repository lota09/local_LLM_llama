import pygame
import sys

# --- 설정 변수 ---
SCREEN_WIDTH = 800
SCREEN_HEIGHT = 600
FPS = 60

# 색상 정의 (RGB)
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
RED = (255, 0, 0)      # 적 (장애물) 색
BLUE = (70, 130, 180)  # 배경 하늘색 느낌

# 물리 상수
GRAVITY = 0.6          # 중력 가속도 (무거움 조절)
JUMP_STRENGTH = -10    # 점프 힘 (-값으로 위로 날라감)
SPEED = 5              # 이동 속도

# --- 클래스 정의 ---

class Player(pygame.sprite.Sprite):
    def __init__(self):
        super().__init__()
        
        # 캐릭터 이미지: 고양이 이모지를 사용했습니다! 
        self.image = pygame.Surface((40, 40))
        self.image.fill(BLACK) # 기본 채우기
        
        # 고양이 얼굴 그리기 (간단하게 눈과 코만 그려서 표현)
        font = pygame.font.Font(None, 36)
        text = "🐈" # 이모지 직접 사용 (이미지가 없어도 됨)
        self.text_surface = font.render(text, True, WHITE)
        self.rect = self.text_surface.get_rect()
        
        # 초기 위치 (화면 중앙 아래에서 시작)
        self.rect.x = SCREEN_WIDTH // 2 - self.rect.width // 2
        self.rect.y = SCREEN_HEIGHT - self.rect.height
        
        self.vel_y = 0   # Y 축 속도 (중력에 의해 증가함)
        self.on_ground = False # 땅에 닿았는지 여부

    def update(self):
        global keys_pressed
        
        # 이동 처리 (X축)
        if keys_pressed[pygame.K_LEFT] or keys_pressed[pygame.K_a]:
            self.rect.x -= SPEED
            
        if keys_pressed[pygame.K_RIGHT] or keys_pressed[pygame.K_d]:
            self.rect.x += SPEED
            
        # 화면 밖으로 나가지 않게 제한
        if self.rect.left < 0: self.rect.left = 0
        if self.rect.right > SCREEN_WIDTH: self.rect.right = SCREEN_WIDTH

        # 점프 처리 (Y축)
        if keys_pressed[pygame.K_UP] or keys_pressed[pygame.K_w] and not self.on_ground:
            self.vel_y = JUMP_STRENGTH
        
        # 중력 적용 및 충돌 감지 로직 단순화 (바닥 체크)
        self.vel_y += GRAVITY
        old_bottom = self.rect.bottom
        
        self.rect.y += int(self.vel_y) 
        
        new_bottom = self.rect.bottom
        
        # 바닥 (지면) 체크: 화면 하단에 도달하면 멈춤
        if new_bottom >= SCREEN_HEIGHT:
             # 간단한 지형 시뮬레이션: 약간 튀어오르는 효과 주거나 바로 정지시킴
             if abs(new_bottom - SCREEN_HEIGHT) <= GRAVITY * 1.5:
                 self.rect.bottom = SCREEN_HEIGHT - 10 # 살짝 띄워줌 (점프 착지감)
                 self.vel_y = 0
                 self.on_ground = True
                 
                 return

class Obstacle(pygame.sprite.Sprite):
    def __init__(self):
        super().__init__()
        
        # 적대 요소: 빨간색 박스 생성
        width, height = 40, 40 
        self.image = pygame.Surface((width, height))
        self.image.fill(RED)
        
        # 랜덤한 위치에 배치하여 게임의 재미를 더합니다.
        import random as rdm
        
        x_pos = rdm.randint(-SCREEN_WIDTH, SCREEN_WIDTH + 100)
        
        # 높이를 조절하여 벽처럼 보이게 함 (높은 곳과 낮은 곳에 위치)
        y_pos = rdm.choice([SCREEN_HEIGHT // 2, SCREEN_HEIGHT // 3])

        self.rect = self.image.get_rect()
        self.rect.topleft = (x_pos, y_pos)


# --- 메인 실행 함수 ---

def main():
    clock = pygame.time.Clock()
    
    # 스크린 초기화 및 디스플레이 설정
    screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
    pygame.display.set_caption("고양이 마리오 🐈")
    
    # 객체 그룹 생성 (충돌 검출 용도 등 확장성을 위해 준비)
    all_sprites_group = pygame.sprite.Group() 
    
    player = Player()
    obstacle_list = [] # 장애물 리스트
    
    for _ in range(8): # 시작할 때 몇 개의 적을 넣을까? -> 8개 정도로 채움
         obs = Obstacle()
         obstacle_list.append(obs)

    running = True
    
    while running:
            dt = clock.tick(FPS) # 프레임 속도 제한
            
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False
                    
            keys_pressed = pygame.key.get_pressed() 
            
            # 플레이어 업데이트 (위치 계산 등)
            player.update() 
            
            # 화면 그리기 (렌더링)
            
            # 배경 색칠하기 (하늘색)
            screen.fill(BLUE) 
            
            # 장애물 그리기 (적색 블록들 표시)
            for obs in obstacle_list:
                screen.blit(obs.image, obs.rect)

            # 고양이 그리기 (주인공 표시)
            screen.blit(player.text_surface, player.rect) 

            pygame.display.flip() # 화면 갱신
            
    pygame.quit()
    sys.exit()

if __name__ == "__main__":
    main()
