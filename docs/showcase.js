const demoPad = document.getElementById('demo-pad');
const demoPill = document.getElementById('demo-pill');
const demoFingers = document.getElementById('demo-fingers');
const demoRelayRing = document.getElementById('demo-relay-ring');
const demoRelayText = document.getElementById('demo-relay-text');
const demoStateBadge = document.getElementById('demo-state-badge');
const demoLog = document.getElementById('demo-log');
const presetButtons = Array.from(document.querySelectorAll('.preset-btn'));

let activeTimers = [];

function clearTimers() {
  for (const id of activeTimers) {
    clearTimeout(id);
  }
  activeTimers = [];
}

function schedule(fn, ms) {
  const id = setTimeout(fn, ms);
  activeTimers.push(id);
}

function renderDots(points) {
  demoFingers.innerHTML = '';
  for (const p of points) {
    const dot = document.createElement('div');
    dot.className = 'demo-dot';
    dot.style.left = `${p.x}%`;
    dot.style.top = `${p.y}%`;
    dot.style.opacity = p.opacity ?? 1;
    demoFingers.appendChild(dot);
  }
}

function setLogs(lines) {
  demoLog.textContent = lines.join('\n');
}

function runPreset(name) {
  clearTimers();
  demoRelayRing.hidden = true;

  if (name === 'drag-relay') {
    demoStateBadge.textContent = 'STATE: THREE_DRAG → RELAY → RESUME';
    demoPill.textContent = '① 三指落屏开始拖动';
    renderDots([{ x: 26, y: 46 }, { x: 36, y: 44 }, { x: 46, y: 46 }]);
    setLogs([
      '→ {"t":"dragStart"}  // clickState=1 防双击误选',
      '→ {"t":"dragMove","dx":18,"dy":2,"accelerate":true}'
    ]);

    schedule(() => {
      demoPill.textContent = '② 拖到屏幕边缘（向右滑动）';
      renderDots([{ x: 64, y: 46 }, { x: 74, y: 44 }, { x: 84, y: 46 }]);
      setLogs([
        '→ {"t":"dragStart"}',
        '→ {"t":"dragMove","dx":84,"dy":0,"accelerate":true}',
        '→ {"t":"dragMove","dx":72,"dy":0,"accelerate":true}'
      ]);
    }, 650);

    schedule(() => {
      demoPill.textContent = '③ 三指抬起：保持左键 400ms 等待接力';
      renderDots([]);
      demoRelayRing.hidden = false;
      demoRelayText.textContent = '接力窗口 400ms：左键仍保持按下';
      demoStateBadge.textContent = 'STATE: IDLE (dragRelayActive = true)';
      setLogs([
        '→ {"t":"dragStart"}',
        '→ {"t":"dragMove","dx":72,"dy":0}',
        '// 抬起三指：暂缓发送 dragEnd，启动 400ms 接力计时'
      ]);
    }, 1400);

    schedule(() => {
      demoRelayRing.hidden = true;
      demoPill.textContent = '④ 300ms 内放回三指：无缝继续拖拽！';
      renderDots([{ x: 26, y: 48 }, { x: 36, y: 46 }, { x: 46, y: 48 }]);
      demoStateBadge.textContent = 'STATE: THREE_DRAG (接力成功)';
      setLogs([
        '→ {"t":"dragStart"}',
        '→ {"t":"dragMove","dx":72,"dy":0}',
        '// 300ms 内三指返回：取消定时器，零中断续拖',
        '→ {"t":"dragMove","dx":64,"dy":4,"accelerate":true}'
      ]);
    }, 2200);

    schedule(() => {
      renderDots([{ x: 62, y: 50 }, { x: 72, y: 48 }, { x: 82, y: 50 }]);
    }, 2750);

    schedule(() => {
      demoPill.textContent = '⑤ 超过 400ms 或单指轻点：释放左键';
      renderDots([]);
      demoStateBadge.textContent = 'STATE: IDLE';
      setLogs([
        '→ {"t":"dragMove","dx":64,"dy":4}',
        '→ {"t":"dragEnd"}  // 左键安全释放'
      ]);
    }, 3550);
    return;
  }

  if (name === 'swipe4') {
    demoStateBadge.textContent = 'STATE: MAYBE_FOUR → GESTURE_LOCKED';
    demoPill.textContent = '错峰落指（65ms 宽限窗口）';
    renderDots([{ x: 32, y: 50 }, { x: 44, y: 47 }, { x: 56, y: 48 }, { x: 68, y: 52 }]);
    setLogs([
      '// 四指先后落屏：MAYBE_ONE → TWO → THREE → MAYBE_FOUR',
      '// 不产生误移动，不提前触发 dragStart'
    ]);

    schedule(() => {
      demoPill.textContent = '四指向左扫：切换到右侧桌面空间';
      renderDots([{ x: 16, y: 50 }, { x: 28, y: 47 }, { x: 40, y: 48 }, { x: 52, y: 52 }]);
      setLogs([
        '→ {"t":"swipe4","dir":"left","naturalSpaces":true}',
        '// Mac 读取符号热键 ID 81，合成 Ctrl + Right',
        '// 进入 GESTURE_LOCKED，抬指前不重复触发'
      ]);
    }, 700);

    schedule(() => {
      demoPill.textContent = '四指张开：显示桌面';
      renderDots([{ x: 18, y: 24 }, { x: 82, y: 24 }, { x: 18, y: 74 }, { x: 82, y: 74 }]);
      setLogs([
        '→ {"t":"spread4"}',
        '// 调用 CoreDockSendNotification("com.apple.showdesktop.awake")'
      ]);
    }, 2000);
    return;
  }

  if (name === 'pinch-scroll') {
    demoStateBadge.textContent = 'STATE: TWO_SCROLL / TWO_PINCH';
    demoPill.textContent = '双指同向滑动 → 120Hz 自然滚动';
    renderDots([{ x: 42, y: 65 }, { x: 58, y: 65 }]);
    setLogs([
      '→ {"t":"scrollBegin"}',
      '→ {"t":"scroll","dx":0,"dy":-24,"natural":true}'
    ]);

    schedule(() => {
      renderDots([{ x: 42, y: 32 }, { x: 58, y: 32 }]);
      setLogs([
        '→ {"t":"scroll","dx":0,"dy":-28,"natural":true}',
        '→ {"t":"scrollEnd","vx":0,"vy":-920,"natural":true}',
        '// Mac 端 120Hz DispatchSourceTimer 指数衰减输出惯性'
      ]);
    }, 650);

    schedule(() => {
      demoPill.textContent = '指距张开主导 → 切换为双指缩放';
      renderDots([{ x: 42, y: 50 }, { x: 58, y: 50 }]);
      setLogs([
        '// 检测到指距变化 Δspan > 质心位移 × 1.15',
        '→ {"t":"pinchBegin"}'
      ]);
    }, 1750);

    schedule(() => {
      renderDots([{ x: 22, y: 50 }, { x: 78, y: 50 }]);
      setLogs([
        '→ {"t":"pinchBegin"}',
        '→ {"t":"pinch","delta":0.16}',
        '→ {"t":"pinchEnd"}'
      ]);
    }, 2400);
    return;
  }

  if (name === 'orientation') {
    demoStateBadge.textContent = 'ORIENTATION: portrait → landscape-right (Δ = 270°)';
    demoPill.textContent = '手机开启竖屏锁定时横放桌面';
    renderDots([{ x: 50, y: 28 }]);
    setLogs([
      '// iPhone 视口保持竖屏 (393×852, screenAngle = 0°)',
      '// 用户设置锁定横屏 Home 条在右 (target = 90°)'
    ]);

    schedule(() => {
      demoPill.textContent = '物理向右划（即竖屏 +Y 方向）→ 映射为 Mac +X';
      renderDots([{ x: 50, y: 74 }]);
      setLogs([
        '// 相对旋转角 = (0° - 90°) mod 360° = 270°',
        '// 原始 touchMove(0, +24) → 旋转映射后 move(+24, 0)',
        '// 若关闭手机竖屏锁且系统已自动横屏，相对角自动归 0°，绝不二次旋转！'
      ]);
    }, 700);
  }
}

for (const btn of presetButtons) {
  btn.addEventListener('click', () => {
    for (const item of presetButtons) {
      item.classList.toggle('active', item === btn);
    }
    runPreset(btn.dataset.preset);
  });
}

let lastMouse = null;
demoPad.addEventListener('pointerdown', (e) => {
  clearTimers();
  demoRelayRing.hidden = true;
  lastMouse = { x: e.clientX, y: e.clientY };
  const rect = demoPad.getBoundingClientRect();
  const px = ((e.clientX - rect.left) / rect.width) * 100;
  const py = ((e.clientY - rect.top) / rect.height) * 100;
  renderDots([{ x: px, y: py }]);
  demoStateBadge.textContent = 'STATE: INTERACTIVE_MOVE';
  demoPill.textContent = '指针移动中';
});

demoPad.addEventListener('pointermove', (e) => {
  if (!lastMouse) return;
  const dx = Math.round(e.clientX - lastMouse.x);
  const dy = Math.round(e.clientY - lastMouse.y);
  lastMouse = { x: e.clientX, y: e.clientY };
  if (dx === 0 && dy === 0) return;
  const rect = demoPad.getBoundingClientRect();
  const px = Math.max(4, Math.min(96, ((e.clientX - rect.left) / rect.width) * 100));
  const py = Math.max(6, Math.min(94, ((e.clientY - rect.top) / rect.height) * 100));
  renderDots([{ x: px, y: py }]);
  setLogs([`→ {"t":"move","dx":${dx},"dy":${dy},"accelerate":true}`]);
});

const endPointer = () => {
  if (!lastMouse) return;
  lastMouse = null;
  renderDots([]);
  demoStateBadge.textContent = 'STATE: IDLE';
};

demoPad.addEventListener('pointerup', endPointer);
demoPad.addEventListener('pointerleave', endPointer);

demoPad.addEventListener(
  'wheel',
  (e) => {
    e.preventDefault();
    clearTimers();
    demoRelayRing.hidden = true;
    demoStateBadge.textContent = 'STATE: TWO_SCROLL';
    demoPill.textContent = '模拟双指自然滚动';
    renderDots([{ x: 44, y: 50 }, { x: 56, y: 50 }]);
    setLogs([
      `→ {"t":"scroll","dx":${Math.round(-e.deltaX)},"dy":${Math.round(-e.deltaY)},"natural":true}`
    ]);
  },
  { passive: false }
);

runPreset('drag-relay');
