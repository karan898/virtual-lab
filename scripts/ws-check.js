const WebSocket = require('ws');

const url = process.argv[2];
const command = process.argv[3];
const expect = process.argv[4];

if (!url || !command || !expect) {
  console.error('Usage: node ws-check.js <url> <command> <expect>');
  process.exit(1);
}

const ws = new WebSocket(url);
let output = '';

ws.on('open', () => {
  // Wait a moment for terminal to settle
  setTimeout(() => {
    ws.send(Buffer.from(command + '\r'));
  }, 1000);
  
  // Wait a bit more and send exit to kill the exec session
  setTimeout(() => {
    ws.send(Buffer.from('exit\r'));
  }, 3000);
});

ws.on('message', (data) => {
  output += data.toString();
});

ws.on('close', (code) => {
  if (code === 4003) {
    console.log('4003 Forbidden');
    process.exit(2);
  }
  
  if (output.includes(expect)) {
    console.log(`PASS: Found expected output "${expect}"`);
    process.exit(0);
  } else {
    console.error(`FAIL: Did not find "${expect}"`);
    console.error(`Output was:\n${output.slice(0, 500)}`); // print first 500 chars
    process.exit(1);
  }
});

ws.on('error', (err) => {
  console.error('WS Error:', err);
  process.exit(1);
});

// Hard timeout
setTimeout(() => {
  console.error('TIMEOUT');
  process.exit(1);
}, 6000);
