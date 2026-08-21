/**
 * Base exercise engine — ported from exercise_engine.dart.
 *
 * Defines the exercise type enum, status object, and abstract engine
 * interface that all specific engines implement.
 */

export const ExerciseType = Object.freeze({
  VERTICAL_JUMP: 'verticalJump',
  PUSH_UP: 'pushUp',
  SQUAT: 'squat',
  CONTROLLED_CRUNCH: 'controlledCrunch',
  WALL_SIT: 'wallSit',
  PLANK: 'plank',
});

export class ExerciseStatus {
  constructor({ primaryText, secondaryText = null, isBodyVisible }) {
    this.primaryText = primaryText;
    this.secondaryText = secondaryText;
    this.isBodyVisible = isBodyVisible;
  }
}

/**
 * Abstract base for all exercise engines.
 * Each engine receives per-frame pose data and maintains its own state machine.
 */
export class ExerciseEngine {
  get status() {
    return new ExerciseStatus({ primaryText: '', isBodyVisible: false });
  }

  reset() {}

  /** @param {Array|null} landmarks  MediaPipe normalized landmarks or null */
  processLandmarks(_landmarks) {}

  /** Raw normalized Y of an adaptive ground guide, or null. */
  get groundGuideY() { return null; }

  /** Whether the UI should show a static position guide. */
  get showPositionGuide() { return false; }
}
