const http = require('http');

http.createServer((req, res) => {
    console.log("Request received");

    res.writeHead(200, {'Content-Type': 'text/plain'});

    // 5MB response (large)
    const big = "X".repeat(1024 * 1024 * 5);

    res.end(big);

}).listen(3000, () => console.log("Backend running on 3000"));
