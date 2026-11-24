import test from 'node:test';
import assert from 'node:assert/strict';
import {
  GestureEngine,
  GestureState,
  resolveRelativeRotationAngle,
  rotateDelta
} from '../../Web/gesture-engine.js';

function createHarness(options = {}) {
  let now = 0;
  let nextTimerId = 1;
  const timers = new Map();
  const events = [];

  const engine = new GestureEngine({
    pointerSensitivity: 1.0,
    pointerAcceleration: true,
    scrollSpeed: 1.0,
    naturalScroll: true,
    naturalSpaces: true,
    dragRelayMs: 400,
    orientationLock: 'auto',
    ...options,
    now: () => now,
    setTimer: (fn, ms) => {
      const id = nextTimerId++;
      timers.set(id, { fn, runAt: now + ms });
      return id;
    },
    clearTimer: (id) => {
      timers.delete(id);
    },
    onEvent: (ev) => {
      events.push(ev);
    }
  });

  function advanceTo(targetMs) {
    assert.ok(targetMs >= now, 'time cannot go backwards');
    while (true) {
      let earliestId = null;
      let earliestTime = Infinity;
      for (const [id, entry] of timers.entries()) {
        if (entry.runAt <= targetMs && entry.runAt < earliestTime) {
          earliestTime = entry.runAt;
          earliestId = id;
        }
      }
      if (earliestId === null) break;
      now = earliestTime;
      const entry = timers.get(earliestId);
      timers.delete(earliestId);
      entry.fn();
    }
    now = targetMs;
  }

  const wrappedEngine = {
    get state() { return engine.state; },
    updateOptions: (p) => engine.updateOptions(p),
    cancelAll: () => engine.cancelAll(),
    touchStart(touches, t = now, vp, allTouches = null) {
      if (t > now) advanceTo(t);
      return engine.touchStart(touches, t, vp, allTouches);
    },
    touchMove(touches, t = now, vp, allTouches = null) {
      if (t > now) advanceTo(t);
      return engine.touchMove(touches, t, vp, allTouches);
    },
    touchEnd(touches, t = now, vp, allTouches = null) {
      if (t > now) advanceTo(t);
      return engine.touchEnd(touches, t, vp, allTouches);
    }
  };

  return {
    engine: wrappedEngine,
    events,
    get now() { return now; },
    advanceTo,
    clearEvents() { events.length = 0; }
  };
}

test('relative software orientation lock avoids double-rotation bug', () => {
  // User locks landscape-right while iOS stays in portrait (screenAngle 0, width < height)
  const lockedInPortrait = resolveRelativeRotationAngle({
    orientationLock: 'landscape-right',
    viewportWidth: 393,
    viewportHeight: 852,
    screenAngle: 0
  });
  assert.equal(lockedInPortrait, 270);
  // Moving down portrait Y (+Y -> toward Home/USB-C edge on right) maps to +X (right)
  assert.deepEqual(rotateDelta(0, 10, lockedInPortrait), { dx: 10, dy: 0 });
  // Moving from X=W to X=0 (-X in portrait -> visually down) maps to +Y (down)
  assert.deepEqual(rotateDelta(-10, 0, lockedInPortrait), { dx: 0, dy: 10 });

  // When iOS HAS auto-rotated into landscape-right (screenAngle 90, width > height), relative angle is 0!
  const alreadyLandscapeRight = resolveRelativeRotationAngle({
    orientationLock: 'landscape-right',
    viewportWidth: 852,
    viewportHeight: 393,
    screenAngle: 90
  });
  assert.equal(alreadyLandscapeRight, 0);
  assert.deepEqual(rotateDelta(10, -5, alreadyLandscapeRight), { dx: 10, dy: -5 });

  // landscape-left while iOS stays in portrait
  const leftInPortrait = resolveRelativeRotationAngle({
    orientationLock: 'landscape-left',
    viewportWidth: 393,
    viewportHeight: 852,
    screenAngle: 0
  });
  assert.equal(leftInPortrait, 90);
  assert.deepEqual(rotateDelta(0, -10, leftInPortrait), { dx: 10, dy: 0 });

  // landscape-left when iOS auto-rotated to 270 -> 0 relative rotation
  assert.equal(
    resolveRelativeRotationAngle({
      orientationLock: 'landscape-left',
      viewportWidth: 852,
      viewportHeight: 393,
      screenAngle: 270
    }),
    0
  );
});

test('1-finger single, double, triple click and reset on 4th tap', () => {
  const h = createHarness();

  // Tap 1
  h.engine.touchStart([{ id: 1, x: 100, y: 100 }], 0);
  h.engine.touchEnd([{ id: 1, x: 101, y: 101 }], 60);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'click', count: 1 }]);

  // Tap 2 within 300ms & <28px
  h.clearEvents();
  h.advanceTo(200);
  h.engine.touchStart([{ id: 2, x: 105, y: 102 }], 200);
  h.engine.touchEnd([{ id: 2, x: 105, y: 102 }], 250);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'click', count: 2 }]);

  // Tap 3
  h.clearEvents();
  h.advanceTo(400);
  h.engine.touchStart([{ id: 3, x: 104, y: 101 }], 400);
  h.engine.touchEnd([{ id: 3, x: 104, y: 101 }], 440);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'click', count: 3 }]);

  // Tap 4 resets back to count 1
  h.clearEvents();
  h.advanceTo(550);
  h.engine.touchStart([{ id: 4, x: 104, y: 101 }], 550);
  h.engine.touchEnd([{ id: 4, x: 104, y: 101 }], 590);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'click', count: 1 }]);

  // Slow tap (>= 230ms) does NOT emit click
  h.clearEvents();
  h.advanceTo(1000);
  h.engine.touchStart([{ id: 5, x: 100, y: 100 }], 1000);
  h.engine.touchEnd([{ id: 5, x: 100, y: 100 }], 1260);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }]);
});

test('1-finger move commits at >=5px or >=230ms', () => {
  const h = createHarness({ pointerSensitivity: 1.5, pointerAcceleration: false });
  h.engine.touchStart([{ id: 1, x: 50, y: 50 }], 0);
  // Small jitter <5px before 230ms does not commit
  h.engine.touchMove([{ id: 1, x: 52, y: 52 }], 15);
  assert.equal(h.events.filter((e) => e.t === 'move').length, 0);

  // Move past 5px commits immediately
  h.engine.touchMove([{ id: 1, x: 58, y: 50 }], 25);
  const moves = h.events.filter((e) => e.t === 'move');
  assert.equal(moves.length, 1);
  assert.deepEqual(moves[0], { t: 'move', dx: 12, dy: 0, accelerate: false });

  h.engine.touchEnd([{ id: 1, x: 58, y: 50 }], 40);
  assert.equal(h.engine.state, GestureState.IDLE);

  // Slow micro-nudge <5px commits once elapsed >= 230ms
  h.clearEvents();
  h.advanceTo(200);
  h.engine.touchStart([{ id: 2, x: 50, y: 50 }], 200);
  h.engine.touchMove([{ id: 2, x: 52, y: 50 }], 320);
  assert.equal(h.events.filter((e) => e.t === 'move').length, 0);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  h.engine.touchMove([{ id: 2, x: 53, y: 50 }], 435);
  const slowMoves = h.events.filter((e) => e.t === 'move');
  assert.equal(slowMoves.length, 1);
  assert.deepEqual(slowMoves[0], { t: 'move', dx: 4.5, dy: 0, accelerate: false });
  h.engine.touchEnd([{ id: 2, x: 53, y: 50 }], 460);
  assert.equal(h.engine.state, GestureState.IDLE);
});

test('1-finger tap and double-tap with 2px touchmove jitter over 100ms emit clicks without move events', () => {
  const h = createHarness({ dragRelayMs: 400 });

  // Single tap lasting 100ms with 2px capacitive jitter at 55ms and 85ms
  h.engine.touchStart([{ id: 1, x: 120, y: 240 }], 0);
  h.engine.touchMove([{ id: 1, x: 122, y: 240 }], 55);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  assert.equal(h.events.filter((e) => e.t === 'move').length, 0);

  h.engine.touchMove([{ id: 1, x: 121, y: 241 }], 85);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  assert.equal(h.events.filter((e) => e.t === 'move').length, 0);

  h.engine.touchEnd([{ id: 1, x: 121, y: 241 }], 100);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'click', count: 1 }]);
  assert.equal(h.events.filter((e) => e.t === 'move').length, 0);
  assert.equal(h.engine.state, GestureState.IDLE);

  // Double-tap with jitter: second tap starts at 220ms and lasts 100ms with jitter at +55ms and +85ms
  h.clearEvents();
  h.advanceTo(220);
  h.engine.touchStart([{ id: 2, x: 123, y: 242 }], 220);
  h.engine.touchMove([{ id: 2, x: 125, y: 242 }], 275);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  h.engine.touchMove([{ id: 2, x: 124, y: 243 }], 305);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  h.engine.touchEnd([{ id: 2, x: 124, y: 243 }], 320);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'click', count: 2 }]);
  assert.equal(h.events.filter((e) => e.t === 'move').length, 0);
  assert.equal(h.engine.state, GestureState.IDLE);

  // 100ms tap with 2px jitter during active drag relay cancels relay cleanly without move or click
  h.clearEvents();
  h.advanceTo(1000);
  h.engine.touchStart([{ id: 10, x: 100, y: 200 }, { id: 11, x: 140, y: 200 }, { id: 12, x: 180, y: 200 }], 1000);
  h.engine.touchMove([{ id: 10, x: 120, y: 200 }, { id: 11, x: 160, y: 200 }, { id: 12, x: 200, y: 200 }], 1070);
  h.engine.touchEnd([{ id: 10, x: 120, y: 200 }, { id: 11, x: 160, y: 200 }, { id: 12, x: 200, y: 200 }], 1100);
  h.clearEvents();
  h.advanceTo(1200);
  h.engine.touchStart([{ id: 13, x: 150, y: 200 }], 1200);
  h.engine.touchMove([{ id: 13, x: 157, y: 200 }], 1255); // 7px < 10px relay threshold
  h.engine.touchMove([{ id: 13, x: 156, y: 201 }], 1285);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  h.engine.touchEnd([{ id: 13, x: 156, y: 201 }], 1300);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 1);
  assert.equal(h.events.some((e) => e.t === 'move' || e.t === 'click'), false);
  assert.equal(h.engine.state, GestureState.IDLE);

  // Slow tap >= 230ms with 2px jitter emits neither click nor move
  h.clearEvents();
  h.advanceTo(1500);
  h.engine.touchStart([{ id: 14, x: 150, y: 200 }], 1500);
  h.engine.touchMove([{ id: 14, x: 152, y: 200 }], 1560);
  h.engine.touchEnd([{ id: 14 }], 1750);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }]);
  assert.equal(h.engine.state, GestureState.IDLE);
});

test('2-finger staggered right-click, scroll with velocity, and uneven lift safety', () => {
  const h = createHarness({ scrollSpeed: 1.0, naturalScroll: true });

  // Staggered 2-finger right click
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }], 0);
  h.engine.touchStart([{ id: 2, x: 150, y: 200 }], 20);
  h.engine.touchEnd([{ id: 1, x: 100, y: 200 }], 90);
  h.engine.touchEnd([{ id: 2, x: 150, y: 200 }], 110);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'rightClick' }]);

  // 2-finger scroll + uneven lift (2 -> 1 -> 0 must not trigger 1-finger move)
  h.clearEvents();
  h.advanceTo(300);
  h.engine.touchStart([{ id: 1, x: 100, y: 300 }, { id: 2, x: 150, y: 300 }], 300);
  h.engine.touchMove([{ id: 1, x: 100, y: 280 }, { id: 2, x: 150, y: 280 }], 350);
  h.engine.touchMove([{ id: 1, x: 100, y: 250 }, { id: 2, x: 150, y: 250 }], 366);
  // First finger lifts
  h.engine.touchEnd([{ id: 1, x: 100, y: 250 }], 372);
  // Remaining finger moves slightly before lifting -> MUST NOT emit pointer move!
  h.engine.touchMove([{ id: 2, x: 170, y: 240 }], 385);
  h.engine.touchEnd([{ id: 2, x: 170, y: 240 }], 395);

  assert.equal(h.events.some((e) => e.t === 'move'), false);
  assert.equal(h.events[1].t, 'scrollBegin');
  const scrolls = h.events.filter((e) => e.t === 'scroll');
  assert.ok(scrolls.length >= 2);
  assert.ok(scrolls[0].dy < 0);
  const scrollEnd = h.events.find((e) => e.t === 'scrollEnd');
  assert.ok(scrollEnd);
  assert.ok(scrollEnd.vy < -500);
  assert.equal(h.engine.state, GestureState.IDLE);
});

test('2-finger pinch disambiguation and lifecycle', () => {
  const h = createHarness();
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }, { id: 2, x: 200, y: 200 }], 0);
  // Spread fingers symmetrically outward (centroid stays 150,200; span 100 -> 140)
  h.engine.touchMove([{ id: 1, x: 80, y: 200 }, { id: 2, x: 220, y: 200 }], 50);
  h.engine.touchMove([{ id: 1, x: 60, y: 200 }, { id: 2, x: 240, y: 200 }], 70);
  h.engine.touchEnd([{ id: 1, x: 60, y: 200 }, { id: 2, x: 240, y: 200 }], 90);

  assert.equal(h.events.some((e) => e.t === 'scrollBegin'), false);
  assert.equal(h.events[1].t, 'pinchBegin');
  const pinchEv = h.events.find((e) => e.t === 'pinch');
  assert.ok(pinchEv && pinchEv.delta > 0);
  assert.equal(h.events.at(-1).t, 'pinchEnd');
});

test('3-finger lookup tap and staggered drag with 0.4s relay resume, tap-cancel, and move-cancel', () => {
  const h = createHarness({ dragRelayMs: 400 });

  // 1. 3-finger tap -> lookup
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }], 0);
  h.engine.touchStart([{ id: 2, x: 140, y: 200 }], 20);
  h.engine.touchStart([{ id: 3, x: 180, y: 200 }], 40);
  h.engine.touchEnd([{ id: 1, x: 100, y: 200 }, { id: 2, x: 140, y: 200 }, { id: 3, x: 180, y: 200 }], 120);
  assert.deepEqual(h.events, [{ t: 'scrollCancel' }, { t: 'lookup' }]);

  // 2. Staggered 3-finger drag + uneven lift + full lift + staggered relay resume within 400ms
  h.clearEvents();
  h.advanceTo(500);
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }], 500);
  h.engine.touchStart([{ id: 2, x: 140, y: 200 }], 520);
  h.engine.touchStart([{ id: 3, x: 180, y: 200 }], 540);
  // Move >= 7px after >= 55ms
  h.engine.touchMove([{ id: 1, x: 112, y: 200 }, { id: 2, x: 152, y: 200 }, { id: 3, x: 192, y: 200 }], 605);
  assert.equal(h.events.filter((e) => e.t === 'dragStart').length, 1);
  assert.equal(h.events.filter((e) => e.t === 'dragMove').length, 1);

  // Uneven lift (3 -> 1 -> 3) stays in drag without emitting dragEnd or move
  h.engine.touchEnd([{ id: 1, x: 112, y: 200 }, { id: 2, x: 152, y: 200 }], 620);
  assert.equal(h.engine.state, GestureState.DRAG_LIFTING);
  h.engine.touchMove([{ id: 3, x: 210, y: 200 }], 630);
  assert.equal(h.events.some((e) => e.t === 'move'), false);

  // Lift last finger -> starts 400ms relay timer, no dragEnd yet!
  h.engine.touchEnd([{ id: 3, x: 210, y: 200 }], 640);
  assert.equal(h.events.some((e) => e.t === 'dragEnd'), false);

  // Staggered 3 fingers return at t = 900..940 (< 400ms elapsed)
  h.advanceTo(900);
  h.engine.touchStart([{ id: 4, x: 80, y: 200 }], 900);
  h.engine.touchStart([{ id: 5, x: 120, y: 200 }], 920);
  h.engine.touchStart([{ id: 6, x: 160, y: 200 }], 940);
  h.engine.touchMove([{ id: 4, x: 95, y: 200 }, { id: 5, x: 135, y: 200 }, { id: 6, x: 175, y: 200 }], 960);

  // Still only 1 dragStart and 0 dragEnd!
  assert.equal(h.events.filter((e) => e.t === 'dragStart').length, 1);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 0);
  assert.equal(h.events.filter((e) => e.t === 'dragMove').length, 2);

  // Lift all at 980 and wait past 400ms -> dragEnd fires automatically at 1380
  h.engine.touchEnd([{ id: 4, x: 95, y: 200 }, { id: 5, x: 135, y: 200 }, { id: 6, x: 175, y: 200 }], 980);
  h.advanceTo(1379);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 0);
  h.advanceTo(1380);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 1);

  // 3. Clean 1-finger tap during relay immediately flushes dragEnd and does NOT click
  h.clearEvents();
  h.advanceTo(2000);
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }, { id: 2, x: 140, y: 200 }, { id: 3, x: 180, y: 200 }], 2000);
  h.engine.touchMove([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 2070);
  h.engine.touchEnd([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 2100);
  h.advanceTo(2200);
  h.engine.touchStart([{ id: 9, x: 150, y: 200 }], 2200);
  h.engine.touchEnd([{ id: 9, x: 150, y: 200 }], 2260);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 1);
  assert.equal(h.events.some((e) => e.t === 'click'), false);

  // 4. 1-finger move during relay flushes dragEnd BEFORE emitting move
  h.clearEvents();
  h.advanceTo(3000);
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }, { id: 2, x: 140, y: 200 }, { id: 3, x: 180, y: 200 }], 3000);
  h.engine.touchMove([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 3070);
  h.engine.touchEnd([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 3100);
  h.advanceTo(3200);
  h.engine.touchStart([{ id: 10, x: 150, y: 200 }], 3200);
  h.engine.touchMove([{ id: 10, x: 175, y: 200 }], 3220);
  const dragEndIdx = h.events.findIndex((e) => e.t === 'dragEnd');
  const moveIdx = h.events.findIndex((e) => e.t === 'move');
  assert.ok(dragEndIdx !== -1 && moveIdx !== -1 && dragEndIdx < moveIdx);
});

test('dragRelayMs = 0 releases drag immediately on lift', () => {
  const h = createHarness({ dragRelayMs: 0 });
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }, { id: 2, x: 140, y: 200 }, { id: 3, x: 180, y: 200 }], 0);
  h.engine.touchMove([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 60);
  h.engine.touchEnd([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 80);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 1);
});

test('staggered 4-finger promotion, swipes, spread4, and pinch4 lock until lift', () => {
  const h = createHarness({ naturalSpaces: true });

  // Staggered 4 fingers landing over 70ms even with 9px drift before 55ms -> promotes to MAYBE_FOUR (no dragStart!)
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }], 0);
  h.engine.touchStart([{ id: 2, x: 140, y: 200 }], 20);
  h.engine.touchStart([{ id: 3, x: 180, y: 200 }], 40);
  h.engine.touchMove([{ id: 1, x: 91, y: 200 }, { id: 2, x: 131, y: 200 }, { id: 3, x: 171, y: 200 }], 55);
  h.engine.touchStart([{ id: 4, x: 220, y: 200 }], 70);
  assert.equal(h.engine.state, GestureState.MAYBE_FOUR);
  assert.equal(h.events.some((e) => e.t === 'dragStart'), false);

  // Swipe left -> single swipe4 left, locked until lift
  h.engine.touchMove([
    { id: 1, x: 50, y: 200 },
    { id: 2, x: 90, y: 200 },
    { id: 3, x: 130, y: 200 },
    { id: 4, x: 170, y: 200 }
  ], 100);
  h.engine.touchMove([
    { id: 1, x: 10, y: 200 },
    { id: 2, x: 50, y: 200 },
    { id: 3, x: 90, y: 200 },
    { id: 4, x: 130, y: 200 }
  ], 120);
  assert.equal(h.engine.state, GestureState.GESTURE_LOCKED);
  assert.deepEqual(h.events.filter((e) => e.t === 'swipe4'), [{ t: 'swipe4', dir: 'left', naturalSpaces: true }]);
  h.engine.touchEnd([{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }], 140);
  assert.equal(h.engine.state, GestureState.IDLE);

  // 4-finger spread -> spread4 (Show Desktop)
  h.clearEvents();
  h.advanceTo(300);
  h.engine.touchStart([
    { id: 1, x: 140, y: 180 },
    { id: 2, x: 160, y: 180 },
    { id: 3, x: 140, y: 200 },
    { id: 4, x: 160, y: 200 }
  ], 300);
  h.engine.touchMove([
    { id: 1, x: 100, y: 140 },
    { id: 2, x: 200, y: 140 },
    { id: 3, x: 100, y: 240 },
    { id: 4, x: 200, y: 240 }
  ], 340);
  assert.deepEqual(h.events.filter((e) => e.t === 'spread4'), [{ t: 'spread4' }]);
  h.engine.touchEnd([{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }], 380);

  // 4-finger pinch -> pinch4 (Launchpad)
  h.clearEvents();
  h.advanceTo(500);
  h.engine.touchStart([
    { id: 1, x: 100, y: 140 },
    { id: 2, x: 200, y: 140 },
    { id: 3, x: 100, y: 240 },
    { id: 4, x: 200, y: 240 }
  ], 500);
  h.engine.touchMove([
    { id: 1, x: 140, y: 180 },
    { id: 2, x: 160, y: 180 },
    { id: 3, x: 140, y: 200 },
    { id: 4, x: 160, y: 200 }
  ], 540);
  assert.deepEqual(h.events.filter((e) => e.t === 'pinch4'), [{ t: 'pinch4' }]);
  h.engine.touchEnd([{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }], 580);

  // Slight finger stagger during fast 4-finger swipe (radiusDelta=19, centroidMove=17) does not trigger spread4
  h.clearEvents();
  h.advanceTo(700);
  h.engine.touchStart([
    { id: 1, x: 100, y: 200 },
    { id: 2, x: 140, y: 200 },
    { id: 3, x: 180, y: 200 },
    { id: 4, x: 220, y: 200 }
  ], 700);
  h.engine.touchMove([
    { id: 1, x: 47, y: 200 },
    { id: 2, x: 121, y: 200 },
    { id: 3, x: 165, y: 200 },
    { id: 4, x: 239, y: 200 }
  ], 720);
  assert.equal(h.events.some((e) => e.t === 'spread4'), false);
  assert.equal(h.engine.state, GestureState.MAYBE_FOUR);
  h.engine.touchMove([
    { id: 1, x: 32, y: 200 },
    { id: 2, x: 106, y: 200 },
    { id: 3, x: 150, y: 200 },
    { id: 4, x: 224, y: 200 }
  ], 740);
  assert.deepEqual(h.events.filter((e) => e.t === 'swipe4'), [{ t: 'swipe4', dir: 'left', naturalSpaces: true }]);
  assert.equal(h.events.some((e) => e.t === 'spread4'), false);
  h.engine.touchEnd([{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }], 780);

  // Stagger boundary (radiusDelta=20, centroidMove=18; 20 <= 18*1.15=20.7) still resolves to swipe4, not spread4
  h.clearEvents();
  h.advanceTo(900);
  h.engine.touchStart([
    { id: 1, x: 100, y: 200 },
    { id: 2, x: 140, y: 200 },
    { id: 3, x: 180, y: 200 },
    { id: 4, x: 220, y: 200 }
  ], 900);
  h.engine.touchMove([
    { id: 1, x: 44, y: 200 },
    { id: 2, x: 120, y: 200 },
    { id: 3, x: 164, y: 200 },
    { id: 4, x: 240, y: 200 }
  ], 920);
  assert.equal(h.events.some((e) => e.t === 'spread4'), false);
  assert.equal(h.engine.state, GestureState.MAYBE_FOUR);
  h.engine.touchMove([
    { id: 1, x: 29, y: 200 },
    { id: 2, x: 105, y: 200 },
    { id: 3, x: 149, y: 200 },
    { id: 4, x: 225, y: 200 }
  ], 940);
  assert.deepEqual(h.events.filter((e) => e.t === 'swipe4'), [{ t: 'swipe4', dir: 'left', naturalSpaces: true }]);
  assert.equal(h.events.some((e) => e.t === 'spread4'), false);
  h.engine.touchEnd([{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }], 980);
});

test('cancelAll cleanly releases drag, relay, scroll, and pinch', () => {
  const h = createHarness({ dragRelayMs: 400 });
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }, { id: 2, x: 140, y: 200 }, { id: 3, x: 180, y: 200 }], 0);
  h.engine.touchMove([{ id: 1, x: 120, y: 200 }, { id: 2, x: 160, y: 200 }, { id: 3, x: 200, y: 200 }], 60);
  h.engine.cancelAll();
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 1);
  assert.equal(h.engine.state, GestureState.IDLE);

  // Active pinch cancel emits pinchEnd
  h.clearEvents();
  h.engine.touchStart([{ id: 1, x: 100, y: 200 }, { id: 2, x: 200, y: 200 }], 100);
  h.engine.touchMove([{ id: 1, x: 70, y: 200 }, { id: 2, x: 230, y: 200 }], 150);
  h.engine.cancelAll();
  assert.equal(h.events.filter((e) => e.t === 'pinchEnd').length, 1);
});

test('ghost touch recovery via allTouches prevents trackpad freeze and stuck drag', () => {
  const h = createHarness({ dragRelayMs: 400 });

  // 1. 4-finger swipe leaves GESTURE_LOCKED; iOS drops touchend for id=4
  const p4 = [
    { id: 1, x: 100, y: 200 },
    { id: 2, x: 140, y: 200 },
    { id: 3, x: 180, y: 200 },
    { id: 4, x: 220, y: 200 }
  ];
  h.engine.touchStart(p4, 0, {}, p4);
  const p4Moved = p4.map((t) => ({ ...t, x: t.x - 50 }));
  h.engine.touchMove(p4Moved, 40, {}, p4Moved);
  assert.equal(h.engine.state, GestureState.GESTURE_LOCKED);
  // Only 1..3 report touchend; id=4 stays ghosted
  h.engine.touchEnd(p4Moved.slice(0, 3), 80, {}, [p4Moved[3]]);
  assert.equal(h.engine.state, GestureState.GESTURE_LOCKED);

  // Next single finger touchStart arrives with allTouches=[{id:5}] -> recovers & clicks
  h.clearEvents();
  h.engine.touchStart([{ id: 5, x: 150, y: 250 }], 200, {}, [{ id: 5, x: 150, y: 250 }]);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
  h.engine.touchEnd([{ id: 5, x: 150, y: 250 }], 240, {}, []);
  assert.deepEqual(h.events.filter((e) => e.t === 'click'), [{ t: 'click', count: 1 }]);

  // 2. Ghosted 3-finger drag recovers cleanly and flushes dragEnd before new touch
  h.clearEvents();
  const p3 = [{ id: 11, x: 100, y: 200 }, { id: 12, x: 140, y: 200 }, { id: 13, x: 180, y: 200 }];
  h.engine.touchStart(p3, 300, {}, p3);
  const p3Moved = p3.map((t) => ({ ...t, x: t.x + 25 }));
  h.engine.touchMove(p3Moved, 370, {}, p3Moved);
  assert.equal(h.engine.state, GestureState.THREE_DRAG);
  // All fingers disappeared silently, new finger id=20 lands
  h.engine.touchStart([{ id: 20, x: 50, y: 50 }], 500, {}, [{ id: 20, x: 50, y: 50 }]);
  assert.equal(h.events.filter((e) => e.t === 'dragEnd').length, 1);
  assert.equal(h.engine.state, GestureState.MAYBE_ONE);
});

test('touch ID swap during scroll, pinch, and drag does not emit jump delta', () => {
  const h = createHarness({ scrollSpeed: 1.0, pointerSensitivity: 1.0, pointerAcceleration: false });

  // Scroll with {1, 2}, accidental palm {3} lands, {1} lifts -> {2, 3} resyncs without giant jump
  h.engine.touchStart([{ id: 1, x: 100, y: 300 }, { id: 2, x: 140, y: 300 }], 0);
  h.engine.touchMove([{ id: 1, x: 100, y: 280 }, { id: 2, x: 140, y: 280 }], 50);
  h.engine.touchStart([{ id: 3, x: 300, y: 700 }], 70);
  h.engine.touchEnd([{ id: 1, x: 100, y: 280 }], 80);
  h.clearEvents();
  h.engine.touchMove([{ id: 2, x: 140, y: 278 }, { id: 3, x: 300, y: 698 }], 95);
  assert.equal(h.events.filter((e) => e.t === 'scroll').length, 0);
  h.engine.touchMove([{ id: 2, x: 140, y: 268 }, { id: 3, x: 300, y: 688 }], 110);
  const scrolls = h.events.filter((e) => e.t === 'scroll');
  assert.equal(scrolls.length, 1);
  assert.deepEqual(scrolls[0], { t: 'scroll', dx: 0, dy: -10, natural: true });
  h.engine.cancelAll();

  // Drag with {10, 11, 12}, palm {13} lands, {10} lifts -> resyncs without cursor teleport
  h.clearEvents();
  h.engine.touchStart([{ id: 10, x: 100, y: 200 }, { id: 11, x: 140, y: 200 }, { id: 12, x: 180, y: 200 }], 200);
  h.engine.touchMove([{ id: 10, x: 120, y: 200 }, { id: 11, x: 160, y: 200 }, { id: 12, x: 200, y: 200 }], 270);
  h.engine.touchStart([{ id: 13, x: 350, y: 600 }], 290);
  h.engine.touchEnd([{ id: 10, x: 120, y: 200 }], 300);
  h.clearEvents();
  h.engine.touchMove([{ id: 11, x: 162, y: 200 }, { id: 12, x: 202, y: 200 }, { id: 13, x: 352, y: 600 }], 320);
  assert.equal(h.events.filter((e) => e.t === 'dragMove').length, 0);
  h.engine.touchMove([{ id: 11, x: 172, y: 200 }, { id: 12, x: 212, y: 200 }, { id: 13, x: 362, y: 600 }], 335);
  const drags = h.events.filter((e) => e.t === 'dragMove');
  assert.equal(drags.length, 1);
  assert.deepEqual(drags[0], { t: 'dragMove', dx: 10, dy: 0, accelerate: false });
});
