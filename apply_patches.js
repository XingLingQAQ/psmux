// Patch Claude Code cli.js to remove Windows blocks for tmux (psmux compatibility)
const fs = require('fs');
const path = require('path');

const cliPath = path.join(
  process.env.APPDATA, 'npm', 'node_modules', '@anthropic-ai', 'claude-code', 'cli.js'
);
const backupPath = cliPath + '.bak';

console.log('Reading cli.js from:', cliPath);
let content = fs.readFileSync(cliPath, 'utf8');
const originalSize = content.length;
console.log('Original size:', (originalSize / 1024 / 1024).toFixed(2), 'MB');

// Create backup
if (!fs.existsSync(backupPath)) {
  fs.copyFileSync(cliPath, backupPath);
  console.log('Backup created at:', backupPath);
} else {
  console.log('Backup already exists, reading from backup for clean patch...');
  content = fs.readFileSync(backupPath, 'utf8');
}

let patchCount = 0;

// === PATCH 1: Remove --tmux CLI flag Windows block ===
// Before: if(Z1()==="windows")process.stderr.write($8.red(`Error: --tmux is not supported on Windows\n`)),process.exit(1);
// After: (removed / no-op)
const patch1_old = 'if(Z1()==="windows")process.stderr.write($8.red(`Error: --tmux is not supported on Windows\n`)),process.exit(1);';
const patch1_find = content.indexOf(patch1_old);
if (patch1_find >= 0) {
  // Replace with a no-op that takes the same logical position
  content = content.substring(0, patch1_find) + 
    '/* psmux-patch: Windows tmux block removed */' + 
    content.substring(patch1_find + patch1_old.length);
  patchCount++;
  console.log('PATCH 1 applied: Removed --tmux Windows block at char', patch1_find);
} else {
  // Try with escaped newlines
  const alt = 'if(Z1()==="windows")process.stderr.write($8.red(`Error: --tmux is not supported on Windows';
  const altIdx = content.indexOf(alt);
  if (altIdx >= 0) {
    // Find the end of this statement (up to process.exit(1);)
    const exitIdx = content.indexOf('process.exit(1)', altIdx);
    if (exitIdx >= 0) {
      const endIdx = content.indexOf(';', exitIdx) + 1;
      content = content.substring(0, altIdx) + 
        '/* psmux-patch: Windows tmux block removed */' +
        content.substring(endIdx);
      patchCount++;
      console.log('PATCH 1 (alt) applied: Removed --tmux Windows block at char', altIdx);
    }
  } else {
    console.log('PATCH 1 FAILED: Could not find --tmux Windows block');
  }
}

// === PATCH 2: Remove execIntoTmuxWorktree (oxY) Windows block ===
// Before: function oxY(q){if(process.platform==="win32")return{handled:!1,error:"Error: --tmux is not supported on Windows"};
// After:  function oxY(q){  (just skip the win32 check)
const patch2_old = 'if(process.platform==="win32")return{handled:!1,error:"Error: --tmux is not supported on Windows"};';
const patch2_find = content.indexOf(patch2_old);
if (patch2_find >= 0) {
  content = content.substring(0, patch2_find) + 
    '/* psmux-patch: win32 worktree block removed */' +
    content.substring(patch2_find + patch2_old.length);
  patchCount++;
  console.log('PATCH 2 applied: Removed execIntoTmuxWorktree win32 block at char', patch2_find);
} else {
  console.log('PATCH 2 FAILED: Could not find oxY win32 block');
}

// === PATCH 3: Update install instruction for Windows ===
// Before: case"windows":return"tmux is not natively available on Windows. Consider using WSL or Cygwin."
// After:  case"windows":return"If psmux is installed, tmux should already be available."
const patch3_old = 'case"windows":return"tmux is not natively available on Windows. Consider using WSL or Cygwin."';
const patch3_new = 'case"windows":return"tmux is available via psmux. Ensure psmux/tmux.exe is in your PATH."';
const patch3_find = content.indexOf(patch3_old);
if (patch3_find >= 0) {
  content = content.substring(0, patch3_find) + patch3_new + content.substring(patch3_find + patch3_old.length);
  patchCount++;
  console.log('PATCH 3 applied: Updated Windows install instructions at char', patch3_find);
} else {
  console.log('PATCH 3 SKIPPED: Install instruction text not found (non-critical)');
}

// Write patched file
fs.writeFileSync(cliPath, content, 'utf8');
console.log('\nPatched file written. New size:', (content.length / 1024 / 1024).toFixed(2), 'MB');
console.log(`Total patches applied: ${patchCount}/3`);

// Verify patches
const verify = fs.readFileSync(cliPath, 'utf8');
const checks = [
  { name: 'PATCH 1', pattern: '/* psmux-patch: Windows tmux block removed */' },
  { name: 'PATCH 2', pattern: '/* psmux-patch: win32 worktree block removed */' },
  { name: 'PATCH 3', pattern: 'tmux is available via psmux' },
];
console.log('\nVerification:');
for (const check of checks) {
  const found = verify.includes(check.pattern);
  console.log(`  ${check.name}: ${found ? 'OK' : 'MISSING'}`);
}

// Also verify the original blocks are gone
const shouldBeGone = [
  'Error: --tmux is not supported on Windows',
  'tmux is not natively available on Windows',
];
console.log('\nBlocks removed:');
for (const text of shouldBeGone) {
  const count = (verify.match(new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length;
  console.log(`  "${text}": ${count === 0 ? 'REMOVED (OK)' : `Still present ${count} times (CHECK)`}`);
}
