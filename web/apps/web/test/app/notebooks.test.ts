import { describe, expect, it } from 'vitest';
import { templateTarget } from '../../app/utils/notebooks';

describe('templateTarget', () => {
  it('uses the open notebook, but never the Templates notebook', () => {
    expect(templateTarget({ kind: 'notebook', id: 'work' }, 'tpl')).toBe('work');
    expect(templateTarget({ kind: 'notebook', id: 'TPL' }, 'tpl')).toBeNull();
    expect(templateTarget({ kind: 'all' }, 'tpl')).toBeNull();
    expect(templateTarget({ kind: 'notebook', id: 'work' }, undefined)).toBe('work');
  });
});
