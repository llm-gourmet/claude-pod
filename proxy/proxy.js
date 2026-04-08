const http = require('http');
const https = require('https');

const UPSTREAM = process.env.REAL_ANTHROPIC_BASE_URL || 'https://api.anthropic.com';

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    const url = new URL(req.url, UPSTREAM);
    const options = {
      hostname: url.hostname,
      port: url.port || 443,
      path: url.pathname + url.search,
      method: req.method,
      headers: {
        ...req.headers,
        host: url.host,
        'content-length': Buffer.byteLength(body)
      }
    };

    const upstreamReq = https.request(options, upstreamRes => {
      let responseBody = '';
      upstreamRes.on('data', chunk => { responseBody += chunk; });
      upstreamRes.on('end', () => {
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        res.end(responseBody);
      });
    });
    upstreamReq.on('error', err => {
      console.error('Upstream error:', err.message);
      res.writeHead(502);
      res.end('Bad Gateway');
    });
    upstreamReq.write(body);
    upstreamReq.end();
  });
});

const PORT = process.env.PROXY_PORT || 8080;
server.listen(PORT, '0.0.0.0', () => {
  console.log(`Proxy listening on :${PORT}`);
});
