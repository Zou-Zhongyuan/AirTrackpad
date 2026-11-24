export const GestureState = Object.freeze({
  IDLE: 'IDLE',
  MAYBE_ONE: 'MAYBE_ONE',
  ONE_MOVE: 'ONE_MOVE',
  MAYBE_TWO: 'MAYBE_TWO',
  MAYBE_TWO_LIFTING: 'MAYBE_TWO_LIFTING',
  TWO_SCROLL: 'TWO_SCROLL',
  TWO_PINCH: 'TWO_PINCH',
  TWO_LIFTING: 'TWO_LIFTING',
  MAYBE_THREE: 'MAYBE_THREE',
  MAYBE_THREE_LIFTING: 'MAYBE_THREE_LIFTING',
  THREE_DRAG: 'THREE_DRAG',
  DRAG_LIFTING: 'DRAG_LIFTING',
  MAYBE_FOUR: 'MAYBE_FOUR',
  GESTURE_LOCKED: 'GESTURE_LOCKED'
});

function normalizeAngle(angle) {
  const numeric = Number.isFinite(Number(angle)) ? Number(angle) : 0;
  return ((Math.round(numeric) % 360) + 360) % 360;
}

export function resolveCurrentScreenAngle({ viewportWidth = 0, viewportHeight = 0, screenAngle = 0 } = {}) {
  const norm = normalizeAngle(screenAngle);
  if (viewportWidth > viewportHeight) {
    return (norm === 90 || norm === 270) ? norm : 90;
  }
  return (norm === 0 || norm === 180) ? norm : 0;
}

export function resolveRelativeRotationAngle({
  orientationLock = 'auto',
  viewportWidth = 0,
  viewportHeight = 0,
  screenAngle = 0
} = {}) {
  if (!orientationLock || orientationLock === 'auto') {
    return 0;
  }

  let targetAngle = 0;
  if (orientationLock === 'landscape-right') {
    targetAngle = 90;
  } else if (orientationLock === 'landscape-left') {
    targetAngle = 270;
  } else if (orientationLock === 'portrait') {
    targetAngle = 0;
  } else {
    return 0;
  }

  const currentAngle = resolveCurrentScreenAngle({ viewportWidth, viewportHeight, screenAngle });
  return ((currentAngle - targetAngle) % 360 + 360) % 360;
}

function cleanZero(n) {
  return n === 0 ? 0 : n;
}

export function rotateDelta(dx, dy, angleDegrees) {
  const angle = normalizeAngle(angleDegrees);
  switch (angle) {
    case 90:
      return { dx: cleanZero(-dy), dy: cleanZero(dx) };
    case 180:
      return { dx: cleanZero(-dx), dy: cleanZero(-dy) };
    case 270:
      return { dx: cleanZero(dy), dy: cleanZero(-dx) };
    default:
      return { dx: cleanZero(dx), dy: cleanZero(dy) };
  }
}

function distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function computeCentroid(points) {
  let sx = 0;
  let sy = 0;
  for (const p of points) {
    sx += p.x;
    sy += p.y;
  }
  const n = points.length || 1;
  return { x: sx / n, y: sy / n };
}

function computeSpan(p1, p2) {
  return Math.hypot(p1.x - p2.x, p1.y - p2.y);
}

function computeAverageRadius(points, centroid) {
  if (!points.length) return 0;
  let sum = 0;
  for (const p of points) {
    sum += distance(p, centroid);
  }
  return sum / points.length;
}

function sameIdTuple(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

export class GestureEngine {
  constructor(options = {}) {
    this.options = {
      pointerSensitivity: 1.2,
      pointerAcceleration: true,
      scrollSpeed: 1.0,
      naturalScroll: true,
      naturalSpaces: true,
      dragRelayMs: 400,
      orientationLock: 'auto',
      ...options
    };

    this.onEvent = typeof options.onEvent === 'function' ? options.onEvent : () => {};
    this.nowFn = typeof options.now === 'function' ? options.now : () => performance.now();
    this.setTimerFn = typeof options.setTimer === 'function'
      ? options.setTimer
      : (fn, ms) => globalThis.setTimeout(fn, ms);
    this.clearTimerFn = typeof options.clearTimer === 'function'
      ? options.clearTimer
      : (id) => globalThis.clearTimeout(id);

    this.state = GestureState.IDLE;
    this.touches = new Map();

    this.gestureStartTime = 0;
    this.phaseStartTime = 0;
    this.prevTime = 0;
    this.lastMoveTime = 0;

    this.primaryTouchId = null;
    this.initialPoint = { x: 0, y: 0 };
    this.prevPoint = { x: 0, y: 0 };
    this.oneMoveHasEmitted = false;
    this.oneMoveEmittedCount = 0;

    this.initialCentroid = { x: 0, y: 0 };
    this.prevCentroid = { x: 0, y: 0 };
    this.maxCentroidDrift = 0;

    this.initialSpan = 0;
    this.prevSpan = 0;
    this.maxSpanDelta = 0;

    this.initialRadius = 0;

    this.scrollVx = 0;
    this.scrollVy = 0;

    this.lastTapTime = -Infinity;
    this.lastTapPos = { x: 0, y: 0 };
    this.lastTapCount = 0;

    this.dragRelayActive = false;
    this.relayTimerId = null;
    this.relayTapConsumed = false;
    this.activeTupleIds = [];
  }

  updateOptions(partial = {}) {
    this.options = { ...this.options, ...partial };
    if (this.options.dragRelayMs <= 0 && this.dragRelayActive) {
      this._flushDragRelay();
    }
  }

  _emit(event) {
    this.onEvent(event);
  }

  _clearRelayTimer() {
    if (this.relayTimerId !== null) {
      this.clearTimerFn(this.relayTimerId);
      this.relayTimerId = null;
    }
  }

  _flushDragRelay() {
    if (!this.dragRelayActive) return;
    this._clearRelayTimer();
    this.dragRelayActive = false;
    this._emit({ t: 'dragEnd' });
  }

  _startDragRelayTimer() {
    this._clearRelayTimer();
    const relayMs = Math.max(0, Number(this.options.dragRelayMs) || 0);
    if (relayMs <= 0) {
      this.dragRelayActive = false;
      this._emit({ t: 'dragEnd' });
      return;
    }

    this.dragRelayActive = true;
    this.relayTimerId = this.setTimerFn(() => {
      this.relayTimerId = null;
      if (!this.dragRelayActive) return;
      this.dragRelayActive = false;
      if (this.state === GestureState.MAYBE_ONE) {
        this.relayTapConsumed = true;
      }
      this._emit({ t: 'dragEnd' });
    }, relayMs);
  }

  _rotationAngle(viewport) {
    return resolveRelativeRotationAngle({
      orientationLock: this.options.orientationLock,
      viewportWidth: viewport?.viewportWidth ?? 0,
      viewportHeight: viewport?.viewportHeight ?? 0,
      screenAngle: viewport?.screenAngle ?? 0
    });
  }

  _syncAllTouches(allTouches) {
    if (!Array.isArray(allTouches)) return;
    const activeIds = new Set(allTouches.map((t) => t.id));
    for (const id of this.touches.keys()) {
      if (!activeIds.has(id)) {
        this.touches.delete(id);
      }
    }
    for (const t of allTouches) {
      this.touches.set(t.id, { id: t.id, x: t.x, y: t.y });
    }
  }

  _points() {
    return Array.from(this.touches.values());
  }

  _enterMaybeOne(now) {
    const pts = this._points();
    const p = pts[0];
    this.state = GestureState.MAYBE_ONE;
    this.phaseStartTime = now;
    this.primaryTouchId = p.id;
    this.initialPoint = { x: p.x, y: p.y };
    this.prevPoint = { x: p.x, y: p.y };
    this.maxCentroidDrift = 0;
    this.oneMoveHasEmitted = false;
    this.oneMoveEmittedCount = 0;
    this.relayTapConsumed = false;
  }

  _enterMaybeTwo(now) {
    const pts = this._points().slice(0, 2);
    const c = computeCentroid(pts);
    const span = computeSpan(pts[0], pts[1]);
    this.state = GestureState.MAYBE_TWO;
    this.phaseStartTime = now;
    this.initialCentroid = c;
    this.prevCentroid = c;
    this.maxCentroidDrift = 0;
    this.initialSpan = span;
    this.prevSpan = span;
    this.maxSpanDelta = 0;
    this.relayTapConsumed = false;
  }

  _enterMaybeThreeOrResumeDrag(now) {
    const pts = this._points().slice(0, 3);
    const c = computeCentroid(pts);
    this.relayTapConsumed = false;
    if (this.dragRelayActive) {
      this._clearRelayTimer();
      this.dragRelayActive = false;
      this.state = GestureState.THREE_DRAG;
      this.phaseStartTime = now;
      this.prevCentroid = c;
      this.initialCentroid = c;
      this.activeTupleIds = pts.map((t) => t.id);
      return;
    }
    this.state = GestureState.MAYBE_THREE;
    this.phaseStartTime = now;
    this.initialCentroid = c;
    this.prevCentroid = c;
    this.maxCentroidDrift = 0;
  }

  _enterMaybeFour(now) {
    this._flushDragRelay();
    this.relayTapConsumed = false;
    const pts = this._points().slice(0, 4);
    const c = computeCentroid(pts);
    this.state = GestureState.MAYBE_FOUR;
    this.phaseStartTime = now;
    this.initialCentroid = c;
    this.prevCentroid = c;
    this.initialRadius = computeAverageRadius(pts, c);
  }

  touchStart(changedTouches = [], now = this.nowFn(), viewport = {}, allTouches = null) {
    if (Array.isArray(allTouches) && this.touches.size > 0 && this.state !== GestureState.IDLE) {
      const allIds = new Set(allTouches.map((t) => t.id));
      const changedIds = new Set(changedTouches.map((t) => t.id));
      let hasSurvivingPreviousTouch = false;
      for (const id of this.touches.keys()) {
        if (!changedIds.has(id) && allIds.has(id)) {
          hasSurvivingPreviousTouch = true;
          break;
        }
      }
      if (!hasSurvivingPreviousTouch) {
        this.cancelAll();
      }
    }

    const prevCount = this.touches.size;
    for (const t of changedTouches) {
      this.touches.set(t.id, { id: t.id, x: t.x, y: t.y });
    }
    if (Array.isArray(allTouches)) {
      this._syncAllTouches(allTouches);
    }

    const count = this.touches.size;
    if (count === 0) return;

    if (prevCount === 0) {
      this.gestureStartTime = now;
      this.relayTapConsumed = false;
      this._emit({ t: 'scrollCancel' });
    }

    if (this.state === GestureState.GESTURE_LOCKED || this.state === GestureState.TWO_LIFTING) {
      return;
    }

    if (this.state === GestureState.DRAG_LIFTING) {
      if (count >= 3) {
        const pts = this._points().slice(0, 3);
        this.prevCentroid = computeCentroid(pts);
        this.activeTupleIds = pts.map((t) => t.id);
        this.state = GestureState.THREE_DRAG;
      }
      return;
    }

    if (this.state === GestureState.IDLE) {
      if (count === 1) {
        this._enterMaybeOne(now);
      } else if (count === 2) {
        this._enterMaybeTwo(now);
      } else if (count === 3) {
        this._enterMaybeThreeOrResumeDrag(now);
      } else {
        this._enterMaybeFour(now);
      }
      return;
    }

    if (this.state === GestureState.MAYBE_ONE) {
      if (count === 2) {
        this._enterMaybeTwo(now);
      } else if (count === 3) {
        this._enterMaybeThreeOrResumeDrag(now);
      } else if (count >= 4) {
        this._enterMaybeFour(now);
      }
      return;
    }

    if (this.state === GestureState.ONE_MOVE) {
      if (!this.oneMoveHasEmitted && (now - this.gestureStartTime) < 90) {
        if (count === 2) {
          this._enterMaybeTwo(now);
        } else if (count === 3) {
          this._enterMaybeThreeOrResumeDrag(now);
        } else if (count >= 4) {
          this._enterMaybeFour(now);
        }
      }
      return;
    }

    if (this.state === GestureState.MAYBE_TWO || this.state === GestureState.MAYBE_TWO_LIFTING) {
      if (count === 2) {
        const pts = this._points().slice(0, 2);
        this.prevCentroid = computeCentroid(pts);
        this.prevSpan = computeSpan(pts[0], pts[1]);
        this.state = GestureState.MAYBE_TWO;
      } else if (count === 3 && ((now - this.phaseStartTime) < 90 || (now - this.gestureStartTime) < 120)) {
        this._enterMaybeThreeOrResumeDrag(now);
      } else if (count >= 4 && ((now - this.phaseStartTime) < 100 || (now - this.gestureStartTime) < 140)) {
        this._enterMaybeFour(now);
      }
      return;
    }

    if (this.state === GestureState.MAYBE_THREE || this.state === GestureState.MAYBE_THREE_LIFTING) {
      if (count === 3) {
        this.prevCentroid = computeCentroid(this._points().slice(0, 3));
        this.state = GestureState.MAYBE_THREE;
      } else if (count >= 4 && ((now - this.phaseStartTime) < 90 || (now - this.gestureStartTime) < 140)) {
        this._enterMaybeFour(now);
      }
    }
  }

  touchMove(changedTouches = [], now = this.nowFn(), viewport = {}, allTouches = null) {
    for (const t of changedTouches) {
      if (this.touches.has(t.id) || allTouches === null) {
        this.touches.set(t.id, { id: t.id, x: t.x, y: t.y });
      }
    }
    if (Array.isArray(allTouches)) {
      this._syncAllTouches(allTouches);
    }

    const angle = this._rotationAngle(viewport);
    const pts = this._points();
    const count = pts.length;
    if (count === 0) {
      if (this.state === GestureState.TWO_SCROLL) {
        const stale = (now - this.lastMoveTime) > 70;
        this._emit({
          t: 'scrollEnd',
          vx: stale ? 0 : this.scrollVx,
          vy: stale ? 0 : this.scrollVy,
          natural: this.options.naturalScroll
        });
        this.state = GestureState.IDLE;
      } else if (this.state === GestureState.TWO_PINCH) {
        this._emit({ t: 'pinchEnd' });
        this.state = GestureState.IDLE;
      } else if (this.state === GestureState.THREE_DRAG || this.state === GestureState.DRAG_LIFTING) {
        this.state = GestureState.IDLE;
        this._startDragRelayTimer();
      } else if (this.state !== GestureState.IDLE) {
        this.state = GestureState.IDLE;
        this.primaryTouchId = null;
      }
      return;
    }

    switch (this.state) {
      case GestureState.IDLE:
      case GestureState.GESTURE_LOCKED:
      case GestureState.TWO_LIFTING:
      case GestureState.DRAG_LIFTING:
      case GestureState.MAYBE_TWO_LIFTING:
      case GestureState.MAYBE_THREE_LIFTING:
        return;

      case GestureState.MAYBE_ONE: {
        const p = this.touches.get(this.primaryTouchId) ?? pts[0];
        const drift = distance(p, this.initialPoint);
        this.maxCentroidDrift = Math.max(this.maxCentroidDrift, drift);
        const elapsed = now - this.phaseStartTime;

        const commitDrift = this.dragRelayActive ? 10 : 5;
        const commitElapsed = 230;

        if (drift >= commitDrift || elapsed >= commitElapsed) {
          this._flushDragRelay();
          this.relayTapConsumed = false;
          this.state = GestureState.ONE_MOVE;
          const rawDx = p.x - this.prevPoint.x;
          const rawDy = p.y - this.prevPoint.y;
          this.prevPoint = { x: p.x, y: p.y };
          if (rawDx !== 0 || rawDy !== 0) {
            const rot = rotateDelta(rawDx, rawDy, angle);
            const dx = rot.dx * this.options.pointerSensitivity;
            const dy = rot.dy * this.options.pointerSensitivity;
            this.oneMoveHasEmitted = true;
            this.oneMoveEmittedCount += 1;
            this._emit({
              t: 'move',
              dx,
              dy,
              accelerate: this.options.pointerAcceleration
            });
          }
        }
        return;
      }

      case GestureState.ONE_MOVE: {
        if (!this.touches.has(this.primaryTouchId)) {
          this.state = GestureState.GESTURE_LOCKED;
          this.primaryTouchId = null;
          return;
        }
        const p = this.touches.get(this.primaryTouchId);
        const rawDx = p.x - this.prevPoint.x;
        const rawDy = p.y - this.prevPoint.y;
        this.prevPoint = { x: p.x, y: p.y };
        if (rawDx === 0 && rawDy === 0) return;
        const rot = rotateDelta(rawDx, rawDy, angle);
        const dx = rot.dx * this.options.pointerSensitivity;
        const dy = rot.dy * this.options.pointerSensitivity;
        this.oneMoveHasEmitted = true;
        this.oneMoveEmittedCount += 1;
        this._emit({
          t: 'move',
          dx,
          dy,
          accelerate: this.options.pointerAcceleration
        });
        return;
      }

      case GestureState.MAYBE_TWO: {
        if (count < 2) return;
        const twoPts = pts.slice(0, 2);
        const c = computeCentroid(twoPts);
        const span = computeSpan(twoPts[0], twoPts[1]);
        const centroidMove = distance(c, this.initialCentroid);
        const spanDelta = Math.abs(span - this.initialSpan);
        this.maxCentroidDrift = Math.max(this.maxCentroidDrift, centroidMove);
        this.maxSpanDelta = Math.max(this.maxSpanDelta, spanDelta);
        const elapsed = now - this.phaseStartTime;

        if (spanDelta >= 12 && spanDelta > centroidMove * 1.15 && (elapsed >= 40 || spanDelta >= 18)) {
          this._flushDragRelay();
          this.state = GestureState.TWO_PINCH;
          this.prevSpan = span;
          this.prevCentroid = c;
          this.activeTupleIds = twoPts.map((t) => t.id);
          this._emit({ t: 'pinchBegin' });
          return;
        }

        if (centroidMove >= 8 && (elapsed >= 45 || centroidMove >= 16)) {
          this._flushDragRelay();
          this.state = GestureState.TWO_SCROLL;
          this.scrollVx = 0;
          this.scrollVy = 0;
          this.prevTime = now;
          this.lastMoveTime = now;
          this.activeTupleIds = twoPts.map((t) => t.id);
          this._emit({ t: 'scrollBegin' });

          const rawDx = c.x - this.prevCentroid.x;
          const rawDy = c.y - this.prevCentroid.y;
          this.prevCentroid = c;
          if (rawDx !== 0 || rawDy !== 0) {
            const rot = rotateDelta(rawDx, rawDy, angle);
            const dx = rot.dx * this.options.scrollSpeed;
            const dy = rot.dy * this.options.scrollSpeed;
            this._emit({
              t: 'scroll',
              dx,
              dy,
              natural: this.options.naturalScroll
            });
          }
        }
        return;
      }

      case GestureState.TWO_SCROLL: {
        if (count < 2) {
          const stale = (now - this.lastMoveTime) > 70;
          this._emit({
            t: 'scrollEnd',
            vx: stale ? 0 : this.scrollVx,
            vy: stale ? 0 : this.scrollVy,
            natural: this.options.naturalScroll
          });
          this.state = GestureState.TWO_LIFTING;
          return;
        }
        const twoPts = pts.slice(0, 2);
        const ids = twoPts.map((t) => t.id);
        const c = computeCentroid(twoPts);
        if (!sameIdTuple(ids, this.activeTupleIds)) {
          this.activeTupleIds = ids;
          this.prevCentroid = c;
          return;
        }
        const rawDx = c.x - this.prevCentroid.x;
        const rawDy = c.y - this.prevCentroid.y;
        this.prevCentroid = c;
        if (rawDx === 0 && rawDy === 0) return;

        const rot = rotateDelta(rawDx, rawDy, angle);
        const dx = rot.dx * this.options.scrollSpeed;
        const dy = rot.dy * this.options.scrollSpeed;

        const dtMs = now - this.prevTime;
        if (dtMs > 0 && dtMs <= 120) {
          const dtSec = Math.max(dtMs / 1000, 0.004);
          const instVx = dx / dtSec;
          const instVy = dy / dtSec;
          const alpha = 0.45;
          this.scrollVx = alpha * instVx + (1 - alpha) * this.scrollVx;
          this.scrollVy = alpha * instVy + (1 - alpha) * this.scrollVy;
        } else if (dtMs > 120) {
          this.scrollVx = 0;
          this.scrollVy = 0;
        }

        this.prevTime = now;
        this.lastMoveTime = now;
        this._emit({
          t: 'scroll',
          dx,
          dy,
          natural: this.options.naturalScroll
        });
        return;
      }

      case GestureState.TWO_PINCH: {
        if (count < 2) {
          this._emit({ t: 'pinchEnd' });
          this.state = GestureState.TWO_LIFTING;
          return;
        }
        const twoPts = pts.slice(0, 2);
        const ids = twoPts.map((t) => t.id);
        const span = computeSpan(twoPts[0], twoPts[1]);
        if (!sameIdTuple(ids, this.activeTupleIds)) {
          this.activeTupleIds = ids;
          this.prevSpan = span;
          return;
        }
        const diff = span - this.prevSpan;
        if (diff === 0) return;
        const denom = Math.max(this.prevSpan, 80);
        const delta = Math.max(-0.35, Math.min(0.35, diff / denom));
        this.prevSpan = span;
        this._emit({ t: 'pinch', delta });
        return;
      }

      case GestureState.MAYBE_THREE: {
        if (count < 3) return;
        const threePts = pts.slice(0, 3);
        const c = computeCentroid(threePts);
        const drift = distance(c, this.initialCentroid);
        this.maxCentroidDrift = Math.max(this.maxCentroidDrift, drift);
        const elapsed = now - this.phaseStartTime;

        if (drift >= 7 && (elapsed >= 55 || drift >= 16)) {
          this._flushDragRelay();
          this.state = GestureState.THREE_DRAG;
          this.activeTupleIds = threePts.map((t) => t.id);
          this._emit({ t: 'dragStart' });

          const rawDx = c.x - this.prevCentroid.x;
          const rawDy = c.y - this.prevCentroid.y;
          this.prevCentroid = c;
          if (rawDx !== 0 || rawDy !== 0) {
            const rot = rotateDelta(rawDx, rawDy, angle);
            this._emit({
              t: 'dragMove',
              dx: rot.dx * this.options.pointerSensitivity,
              dy: rot.dy * this.options.pointerSensitivity,
              accelerate: this.options.pointerAcceleration
            });
          }
        }
        return;
      }

      case GestureState.THREE_DRAG: {
        if (count < 3) {
          this.state = GestureState.DRAG_LIFTING;
          return;
        }
        const threePts = pts.slice(0, 3);
        const ids = threePts.map((t) => t.id);
        const c = computeCentroid(threePts);
        if (!sameIdTuple(ids, this.activeTupleIds)) {
          this.activeTupleIds = ids;
          this.prevCentroid = c;
          return;
        }
        const rawDx = c.x - this.prevCentroid.x;
        const rawDy = c.y - this.prevCentroid.y;
        this.prevCentroid = c;
        if (rawDx === 0 && rawDy === 0) return;

        const rot = rotateDelta(rawDx, rawDy, angle);
        this._emit({
          t: 'dragMove',
          dx: rot.dx * this.options.pointerSensitivity,
          dy: rot.dy * this.options.pointerSensitivity,
          accelerate: this.options.pointerAcceleration
        });
        return;
      }

      case GestureState.MAYBE_FOUR: {
        if (count < 4) return;
        const fourPts = pts.slice(0, 4);
        const c = computeCentroid(fourPts);
        const rawDx = c.x - this.initialCentroid.x;
        const rawDy = c.y - this.initialCentroid.y;
        const rot = rotateDelta(rawDx, rawDy, angle);
        const centroidMove = Math.hypot(rot.dx, rot.dy);

        const radius = computeAverageRadius(fourPts, c);
        const radiusDelta = radius - this.initialRadius;

        if (Math.abs(radiusDelta) >= 20 && Math.abs(radiusDelta) > centroidMove * 1.15) {
          this.state = GestureState.GESTURE_LOCKED;
          this._emit({ t: radiusDelta > 0 ? 'spread4' : 'pinch4' });
          return;
        }

        if (centroidMove >= 28) {
          this.state = GestureState.GESTURE_LOCKED;
          let dir;
          if (Math.abs(rot.dx) >= Math.abs(rot.dy)) {
            dir = rot.dx < 0 ? 'left' : 'right';
          } else {
            dir = rot.dy < 0 ? 'up' : 'down';
          }
          this._emit({
            t: 'swipe4',
            dir,
            naturalSpaces: this.options.naturalSpaces
          });
        }
        return;
      }
    }
  }

  touchEnd(changedTouches = [], now = this.nowFn(), viewport = {}, allTouches = null) {
    for (const t of changedTouches) {
      this.touches.delete(t.id);
    }
    if (Array.isArray(allTouches)) {
      this._syncAllTouches(allTouches);
    }

    const count = this.touches.size;

    switch (this.state) {
      case GestureState.IDLE:
        return;

      case GestureState.GESTURE_LOCKED:
      case GestureState.TWO_LIFTING:
        if (count === 0) {
          this.state = GestureState.IDLE;
        }
        return;

      case GestureState.MAYBE_ONE: {
        if (count > 0) return;
        const elapsed = now - this.phaseStartTime;
        const endTouch = changedTouches[0];
        const lastPos = (endTouch && Number.isFinite(endTouch.x) && Number.isFinite(endTouch.y))
          ? { x: endTouch.x, y: endTouch.y }
          : this.prevPoint;
        const endDrift = Math.max(this.maxCentroidDrift, distance(lastPos, this.initialPoint));
        const isTap = elapsed < 230 && endDrift < 10;

        if (this.dragRelayActive) {
          this._flushDragRelay();
          this.lastTapCount = 0;
          this.state = GestureState.IDLE;
          return;
        }

        if (this.relayTapConsumed) {
          this.relayTapConsumed = false;
          this.lastTapCount = 0;
          this.state = GestureState.IDLE;
          return;
        }

        if (isTap) {
          const withinChain = (now - this.lastTapTime) <= 300 &&
            distance(lastPos, this.lastTapPos) < 28;
          const clickCount = withinChain ? Math.min(3, this.lastTapCount + 1) : 1;
          this.lastTapTime = now;
          this.lastTapPos = lastPos;
          this.lastTapCount = clickCount === 3 ? 0 : clickCount;
          this._emit({ t: 'click', count: clickCount });
        }
        this.state = GestureState.IDLE;
        return;
      }

      case GestureState.ONE_MOVE:
        if (count === 0) {
          this.state = GestureState.IDLE;
          this.primaryTouchId = null;
        } else if (!this.touches.has(this.primaryTouchId)) {
          this.state = GestureState.GESTURE_LOCKED;
          this.primaryTouchId = null;
        }
        return;

      case GestureState.MAYBE_TWO:
      case GestureState.MAYBE_TWO_LIFTING: {
        if (count > 0) {
          this.state = GestureState.MAYBE_TWO_LIFTING;
          return;
        }
        const elapsed = now - this.phaseStartTime;
        if (elapsed < 230 && this.maxCentroidDrift < 12 && this.maxSpanDelta < 12) {
          this._flushDragRelay();
          this._emit({ t: 'rightClick' });
        }
        this.state = GestureState.IDLE;
        return;
      }

      case GestureState.TWO_SCROLL: {
        if (count < 2) {
          const stale = (now - this.lastMoveTime) > 70;
          const vx = stale ? 0 : this.scrollVx;
          const vy = stale ? 0 : this.scrollVy;
          this._emit({
            t: 'scrollEnd',
            vx,
            vy,
            natural: this.options.naturalScroll
          });
          this.state = count === 0 ? GestureState.IDLE : GestureState.TWO_LIFTING;
        }
        return;
      }

      case GestureState.TWO_PINCH: {
        if (count < 2) {
          this._emit({ t: 'pinchEnd' });
          this.state = count === 0 ? GestureState.IDLE : GestureState.TWO_LIFTING;
        }
        return;
      }

      case GestureState.MAYBE_THREE:
      case GestureState.MAYBE_THREE_LIFTING: {
        if (count > 0) {
          this.state = GestureState.MAYBE_THREE_LIFTING;
          return;
        }
        const elapsed = now - this.phaseStartTime;
        if (elapsed < 250 && this.maxCentroidDrift < 12) {
          this._flushDragRelay();
          this._emit({ t: 'lookup' });
        }
        this.state = GestureState.IDLE;
        return;
      }

      case GestureState.THREE_DRAG: {
        if (count === 0) {
          this.state = GestureState.IDLE;
          this._startDragRelayTimer();
        } else if (count < 3) {
          this.state = GestureState.DRAG_LIFTING;
        }
        return;
      }

      case GestureState.DRAG_LIFTING: {
        if (count === 0) {
          this.state = GestureState.IDLE;
          this._startDragRelayTimer();
        }
        return;
      }

      case GestureState.MAYBE_FOUR: {
        if (count === 0) {
          this.state = GestureState.IDLE;
        } else {
          this.state = GestureState.GESTURE_LOCKED;
        }
        return;
      }
    }
  }

  cancelAll() {
    this._clearRelayTimer();
    this.touches.clear();

    if (
      this.dragRelayActive ||
      this.state === GestureState.THREE_DRAG ||
      this.state === GestureState.DRAG_LIFTING
    ) {
      this.dragRelayActive = false;
      this._emit({ t: 'dragEnd' });
    }
    if (this.state === GestureState.TWO_SCROLL) {
      this._emit({ t: 'scrollCancel' });
    }
    if (this.state === GestureState.TWO_PINCH) {
      this._emit({ t: 'pinchEnd' });
    }

    this.state = GestureState.IDLE;
    this.primaryTouchId = null;
    this.relayTapConsumed = false;
    this.activeTupleIds = [];
  }
}
