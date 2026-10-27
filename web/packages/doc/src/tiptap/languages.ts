/** Native `CodeLanguage(identifier:)` aliases → the canonical id a codeBlock's `language` holds. */
const CODE_LANGUAGE_ALIASES: Record<string, string> = {
  text: 'text', txt: 'text', plain: 'text', plaintext: 'text',
  bash: 'bash', sh: 'bash', shell: 'bash', zsh: 'bash', console: 'bash', shellsession: 'bash',
  c: 'c', h: 'c',
  cpp: 'cpp', 'c++': 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp',
  csharp: 'csharp', cs: 'csharp', 'c#': 'csharp',
  css: 'css', scss: 'css',
  go: 'go', golang: 'go',
  html: 'html', xml: 'html', xhtml: 'html', svg: 'html', plist: 'html',
  java: 'java',
  javascript: 'javascript', js: 'javascript', jsx: 'javascript', mjs: 'javascript', node: 'javascript',
  json: 'json', jsonc: 'json',
  kotlin: 'kotlin', kt: 'kotlin', kts: 'kotlin',
  markdown: 'markdown', md: 'markdown',
  php: 'php',
  python: 'python', py: 'python', python3: 'python',
  ruby: 'ruby', rb: 'ruby',
  rust: 'rust', rs: 'rust',
  sql: 'sql', mysql: 'sql', postgresql: 'sql', postgres: 'sql', sqlite: 'sql',
  swift: 'swift',
  typescript: 'typescript', ts: 'typescript', tsx: 'typescript',
  yaml: 'yaml', yml: 'yaml',
};

/** A Markdown info string or alias (`py`, `c++`, `yml`…) → canonical language id; undefined when unknown. */
export function codeLanguageId(raw: string): string | undefined {
  const word = raw.trim().split(/[ {,]/)[0] ?? '';
  return CODE_LANGUAGE_ALIASES[word.toLowerCase()];
}
