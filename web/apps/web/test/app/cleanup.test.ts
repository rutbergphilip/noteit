import { describe, expect, it } from 'vitest';
import { CLEANUP, cleanupButtonState, cleanupResultText, fileSize } from '../../app/utils/cleanup';

describe('Clean Up Unused Storage', () => {
  it('uses the Mac wording', () => {
    expect(CLEANUP.title).toBe('Clean up unused storage?');
    expect(CLEANUP.confirm).toBe('Clean Up');
    expect(CLEANUP.message).toMatch(/^This removes leftover copies of notes that were never finished saving/);
  });

  it('reports what was removed', () => {
    expect(cleanupResultText({ deletedObjects: 1, deletedBytes: 532 })).toBe('Removed 1 item (532 bytes)');
    expect(cleanupResultText({ deletedObjects: 3, deletedBytes: 1_500_000 })).toBe('Removed 3 items (1.5 MB)');
    expect(cleanupResultText({ deletedObjects: 0, deletedBytes: 0 })).toBe('Removed 0 items (Zero KB)');
    expect(fileSize(12_400)).toBe('12 KB');
  });

  it('is enabled only when connected to storage with atomic conditional writes', () => {
    expect(cleanupButtonState(true, true)).toEqual({ enabled: true });
    expect(cleanupButtonState(true, false)).toEqual({ enabled: false, caption: CLEANUP.unavailableCaption });
    expect(cleanupButtonState(false, false)).toEqual({ enabled: false });
  });
});
