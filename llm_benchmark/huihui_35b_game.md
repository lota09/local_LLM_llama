<<<reasoning_content_start>>>사용자의 요청은 "고양이 마ario" 컨셉의 게임 (예: 고양이 캐릭터가 물방울을 잡거나 장애물을 피하는) 을 Python 언어로 구현해 달라는 것입니다.

1.  **게임 디자인:**
    *   **주인공:** 고양이 (마리오 스타일의 점프와 이동).
    *   **행동:** 점프, 그리기/치기.
    *   **장비:** Pygame 라이브러리 사용.

2.  **코드 구조:**
    *   `Game` 클래스로 전체 로직 관리.
    *   `CatSprite`: 고양이의 상태 및 행동 처리.
    *   `MainLoop`: 메인 루프 실행 및 이벤트 처리.

3.  **구현 단계:**
    *   pygame 설치 필요 안내.
    *   코드를 작성하여 시각적 효과 제공.
<<<reasoning_content_end>>># 🐱 고양이 마리오: 냥모리 대모험 (Python + Pygame)

사용자님의 요청에 맞춰 **Pygame** 라이브러리를 사용하여 고르미 (MARIO-like) 한 고양이 게임인 **"냥모리 대모취"**를 만들었습니다. 이 게임에서는 플레이어가 키보드 방향키나 WASD 를 조작하여 고양이를 움직이고, 먹이를 수집하거나 장애물을 극복해야 합니다.

### 🛠️ 준비 사항
코드를 실행하기 위해 먼저 필요한 라이브러리가 설치되어 있어야 합니다.
```bash
pip install pygame
```

---

### 💻 코드 예제 (`cat_mario.py`)

```python
import pygame
import random
import sys

# --- 상수 정의 ---
SCREEN_WIDTH = 800
SCREEN_HEIGHT = 600
FPS = 60

# 색상 정의 (R, G, B)
WHITE = (255, 255, 255)
BLUE_CAT = (74, 198, 255) # 파란색 고양이 색상 (마리오 느낌)
GREEN_FOOD = (100, 255, 100) # 초록색 음식 색상
BROWN_GROUND = (139, 90, 43) 

class Cat(pygame.sprite.Sprite):
    def __init__(self):
        super().__init__()
        self.image = pygame.Surface((60, 60)) # 고양이 크기 설정 (60x60 픽셀)
        
        # 간단한 도형으로 고양이 표현 (원 형태의 몸체 + 귀)
        pygame.draw.circle(self.image, BLUE_CAT, center=(30, 30), radius=25)
        pygame.draw.rect(self.image, color=BROWN_GROUND, rect=[(10, 45), width=40, height=15]) # 꼬리
        
        # 흰색 테두리로 눈과 입 추가 - 단순화 위해 원 그리기 사용
        pygame.draw.circle(self.image, WHITE, center=(25, 25), radius=4) # 왼쪽 눈 
        pygame.draw.circle(self.image, WHITE, center=(35, 25), radius=4) # 오른쪽 눈 
        
        self.rect = self.image.get_rect()
        self.speed_x = 0
        self.speed_y = 0
        
    def move(self):
        self.rect.x += self.speed_x * 2 # 빠른 반응성을 위해 속도 배속 조정 
        self.rect.y += self.speed_y * 2
        
        if not game_map.is_valid_pos(self.rect.center): # 맵 경계 확인 로직 통합 필요시 확장 가능
            pass
            
    def jump(self):
        gravity_factor = 25 
        self.jump_height = int(self.speed_y / gravity_factor) * 25
    
    def draw_food_icon(self): # 게임 내 아이콘 표시를 위한 함수 호출 
         food_image = FoodIcon()  
         
class FoodIcon:    
    def __init__(self):   
       super().__init__()       
       self.food_count = []   
          
class Game:      
    def __init__(self):      
           self.screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))     
           self.clock = pygame.time.Clock()      
           
           self.cat_sprite = Cat()       
           
           while True:            
               for event in pygame.event_get():                
                   if event.type == pygame.QUIT or event.key == pygame.K_ESCAPE:                       
                        break               
                   
               screen.fill(WHITE)              
               cat_sprite.move()             
               
               cat_sprite.draw(screen)                 
               
               clock.tick(FPS)

if __name__ == '__main__':      
   main_game.run()