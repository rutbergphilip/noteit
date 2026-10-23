import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';
import { hash, verify } from '@node-rs/argon2';
import { Mutex, readIfExists, writeFileAtomic } from './files';

export type Uuid = string;

export interface S3Key {
  accessKeyId: string;
  secretAccessKey: string;
  label: string;
  createdAt: string;
  lastUsedAt?: string;
}

export interface User {
  id: Uuid;
  username: string;
  displayName: string;
  role: 'admin' | 'user';
  status: 'active' | 'disabled' | 'deleting';
  passwordHash?: string;
  sessionEpoch: number;
  mustChangePassword: boolean;
  quotaBytes: number;
  maxObjects: number;
  s3Keys: S3Key[];
  createdAt: string;
  lastSeenAt?: string;
}

export interface Invite {
  id: Uuid;
  tokenSha256: string;
  role: 'admin' | 'user';
  quotaBytes?: number;
  maxObjects?: number;
  createdBy: Uuid;
  createdAt: string;
  expiresAt: string;
  usedAt?: string;
  usedBy?: Uuid;
  revokedAt?: string;
}

export interface AccountsFile {
  schemaVersion: 1;
  users: User[];
  invites: Invite[];
}

export class ApiFailure extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message = code,
  ) {
    super(message);
  }
}

export const USERNAME_RE = /^[a-z0-9][a-z0-9._-]{1,31}$/;
export const MIN_PASSWORD_LENGTH = 10;

// algorithm 2 = Argon2id (@node-rs/argon2's Algorithm is an ambient const enum, not importable as a value here).
const ARGON = { algorithm: 2, memoryCost: 19456, timeCost: 2, parallelism: 1 };

export function hashPassword(password: string): Promise<string> {
  return hash(password, ARGON);
}

export async function verifyPassword(hashed: string | undefined, password: string): Promise<boolean> {
  if (!hashed) {
    // Spend comparable time so unknown usernames aren't distinguishable by timing.
    await hash(password, ARGON);
    return false;
  }
  try {
    return await verify(hashed, password);
  } catch {
    return false;
  }
}

export function checkPassword(password: unknown): string {
  if (typeof password !== 'string' || password.length < MIN_PASSWORD_LENGTH || password.length > 1024) {
    throw new ApiFailure(400, 'badRequest', `Passwords need at least ${MIN_PASSWORD_LENGTH} characters.`);
  }
  return password;
}

export const sha256hex = (s: string) => createHash('sha256').update(s).digest('hex');

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(sha256hex(a));
  const y = Buffer.from(sha256hex(b));
  return timingSafeEqual(x, y) && a === b;
}

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function newAccessKeyId(): string {
  const bytes = randomBytes(17);
  return `NIK${[...bytes].map((b) => BASE32[b % 32]).join('')}`;
}
export const newSecret = () => randomBytes(30).toString('base64url');
export const newUserId = () => randomUUID().toUpperCase();

/** Throws 409 lastAdmin when a change would leave no active admin. */
export function assertNotLastAdmin(f: AccountsFile, change: { userId: Uuid; role?: 'user'; status?: 'disabled' | 'deleting' }): void {
  const activeAdmins = f.users.filter((u) => u.role === 'admin' && u.status === 'active');
  const target = activeAdmins.find((u) => u.id === change.userId);
  if (target && activeAdmins.length === 1 && (change.role === 'user' || change.status)) {
    throw new ApiFailure(409, 'lastAdmin', 'There must be at least one active admin.');
  }
}

/** /data/accounts.json, mode 0600, written temp → fsync → rename under one mutex. */
export class AccountStore {
  private file: AccountsFile = { schemaVersion: 1, users: [], invites: [] };
  private readonly mutex = new Mutex();
  private readonly path: string;

  constructor(dataDir: string) {
    this.path = join(dataDir, 'accounts.json');
  }

  async load(): Promise<void> {
    const raw = await readIfExists(this.path);
    if (raw) this.file = JSON.parse(raw) as AccountsFile;
  }

  get users(): readonly User[] {
    return this.file.users;
  }
  get invites(): readonly Invite[] {
    return this.file.invites;
  }
  get isEmpty(): boolean {
    return this.file.users.length === 0;
  }

  /** The only writer: applies `fn` to a copy and saves it; the in-memory state changes only once saved. */
  mutate<T>(fn: (f: AccountsFile) => T): Promise<T> {
    return this.mutex.run(async () => {
      const copy = JSON.parse(JSON.stringify(this.file)) as AccountsFile;
      const result = fn(copy);
      await writeFileAtomic(this.path, JSON.stringify(copy, null, 2));
      this.file = copy;
      return result;
    });
  }

  byId(id: Uuid): User | undefined {
    return this.file.users.find((u) => u.id === id);
  }
  byUsername(username: string): User | undefined {
    return this.file.users.find((u) => u.username === username.toLowerCase());
  }
  byAccessKey(id: string): { user: User; key: S3Key } | undefined {
    for (const user of this.file.users) {
      const key = user.s3Keys.find((k) => k.accessKeyId === id);
      if (key) return { user, key };
    }
    return undefined;
  }
}
