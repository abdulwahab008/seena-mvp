const USERNAME_AT_SCHOOL = /^([a-z0-9][a-z0-9._-]{2,31})@([a-z0-9][a-z0-9-]{2,49})$/i;

// 'ahmed.t@seena-main' is a username login: Supabase Auth only knows the hidden
// address create_user_account() gave it. A real email always has a dot after the @.
export function expandUsernameLogin(identifier: string): string {
  const m = identifier.trim().match(USERNAME_AT_SCHOOL);
  return m ? `${m[1]}@${m[2]}.users.seena.local`.toLowerCase() : identifier.trim();
}
