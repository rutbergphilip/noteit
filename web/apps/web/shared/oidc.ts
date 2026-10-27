/**
 * OIDC sign-in outcomes the callback hands to the SPA in the URL fragment (`/#oidc-error=<code>`), with the text it
 * shows. A fragment never reaches a server or a Referer.
 */
export const OIDC_ERRORS = {
  notLinked: 'No NoteIt account is linked to this sign-in. Ask your admin for an invite.',
  expired: 'The sign-in took too long or was started in another tab. Try again.',
  denied: 'Sign-in was cancelled.',
  failed: "Sign-in didn't work. Try again, or ask your admin to check the server log.",
  unavailable: "The identity provider can't be reached. Try again shortly.",
  disabled: "This account can't sign in. Ask your admin.",
  alreadyLinked: 'This sign-in is already linked to another NoteIt account.',
  inviteInvalid: 'This invite is no longer valid.',
  usernameTaken: 'That username is taken. Choose another one and try again.',
  setupDone: 'This server already has an admin.',
  setupRequired: 'This server needs its first admin. Set it up with the setup token first.',
} as const;

export type OidcErrorCode = keyof typeof OIDC_ERRORS;

export const OIDC_INTENTS = ['login', 'link', 'invite', 'setup'] as const;
export type OidcIntent = (typeof OIDC_INTENTS)[number];
