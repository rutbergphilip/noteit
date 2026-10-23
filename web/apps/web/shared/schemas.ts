import { z } from 'zod';

/**
 * Input contracts for the control-plane actions. The server validates with them (`.schema()`) and the forms reuse
 * them as `clientSchema`, so a field error shows before the round trip and the two sides can't drift.
 */

export const USERNAME_RE = /^[a-z0-9][a-z0-9._-]{1,31}$/;
export const MIN_PASSWORD_LENGTH = 10;

export const username = z
  .string()
  .trim()
  .toLowerCase()
  .regex(USERNAME_RE, 'Use 2–32 lowercase letters, digits, dots, dashes or underscores.');

export const newPassword = z
  .string()
  .min(MIN_PASSWORD_LENGTH, `Use at least ${MIN_PASSWORD_LENGTH} characters.`)
  .max(1024, 'That password is too long.');

/** Never length-checked on sign-in: the answer must not depend on how the stored password was chosen. */
const anyPassword = z.string().min(1, 'Enter your password.').max(1024);

const displayName = z.string().trim().max(64, 'Use at most 64 characters.');
const positiveInt = z.number().int().positive();

export const setupInput = z.object({
  token: z.string().trim().min(1, 'Paste the setup token from the server log.').max(200),
  username,
  password: newPassword,
  displayName: displayName.optional(),
});

export const signInInput = z.object({
  username: z.string().trim().toLowerCase().min(1, 'Enter your username.').max(64),
  password: anyPassword,
});

export const redeemInviteInput = z.object({
  token: z.string().trim().min(1, 'Paste the invite token.').max(200),
  username,
  password: newPassword,
  displayName: displayName.optional(),
});

export const changePasswordInput = z.object({
  current: anyPassword,
  next: newPassword,
});

export const updateProfileInput = z.object({
  displayName: displayName.min(1, 'Enter a name.'),
});

export const createS3KeyInput = z.object({
  label: z.string().trim().max(64).optional(),
});

export const accessKeyInput = z.object({ accessKeyId: z.string().min(1).max(64) });

export const role = z.enum(['admin', 'user']);

export const createUserInput = z.object({
  username,
  displayName: displayName.optional(),
  role: role.default('user'),
  quotaBytes: positiveInt.optional(),
  maxObjects: positiveInt.max(10_000_000).optional(),
});

export const updateUserInput = z.object({
  id: z.string().min(1).max(64),
  role: role.optional(),
  status: z.enum(['active', 'disabled']).optional(),
  displayName: displayName.min(1).optional(),
  quotaBytes: positiveInt.optional(),
  maxObjects: positiveInt.max(10_000_000).optional(),
});

export const userIdInput = z.object({ id: z.string().min(1).max(64) });

export const deleteUserInput = z.object({
  id: z.string().min(1).max(64),
  confirmUsername: z.string().max(64),
});

export const createInviteInput = z.object({
  role: role.default('user'),
  ttlHours: z
    .number()
    .positive()
    .max(24 * 30)
    .optional(),
  quotaBytes: positiveInt.optional(),
});
