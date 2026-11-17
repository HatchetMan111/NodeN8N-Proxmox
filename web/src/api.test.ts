import { describe, expect, it, vi } from 'vitest';
import { fetchJSON, formatUptime } from './api';

describe('fetchJSON', () => {
  it('parses a successful JSON response', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ status: 'ok' }),
      }),
    );
    await expect(fetchJSON('/api/health')).resolves.toEqual({ status: 'ok' });
    vi.unstubAllGlobals();
  });

  it('throws with path and status on HTTP error', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 503 }),
    );
    await expect(fetchJSON('/api/system')).rejects.toThrow('/api/system: HTTP 503');
    vi.unstubAllGlobals();
  });
});

describe('formatUptime', () => {
  it('formats days, hours and minutes', () => {
    expect(formatUptime(90061)).toBe('1d 1h 1m');
    expect(formatUptime(3660)).toBe('1h 1m');
    expect(formatUptime(120)).toBe('2m');
  });
});
