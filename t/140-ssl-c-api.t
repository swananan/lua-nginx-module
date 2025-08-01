# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;

repeat_each(3);

# All these tests need to have new openssl
my $NginxBinary = $ENV{'TEST_NGINX_BINARY'} || 'nginx';
my $openssl_version = eval { `$NginxBinary -V 2>&1` };

if ($openssl_version =~ m/built with OpenSSL (0|1\.0\.(?:0|1[^\d]|2[a-d]).*)/) {
    plan(skip_all => "too old OpenSSL, need 1.0.2e, was $1");
} elsif ($openssl_version =~ m/BoringSSL/) {
    $ENV{TEST_NGINX_USE_BORINGSSL} = 1;
    plan tests => repeat_each() * (blocks() * 6 - 6);
} else {
    plan tests => repeat_each() * (blocks() * 5 - 5);
    $ENV{TEST_NGINX_USE_OPENSSL} = 1;
}

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

#log_level 'warn';
log_level 'debug';

no_long_string();
#no_diff();

add_block_preprocessor(sub {
    my $block = shift;

    if (!defined $block->user_files) {
        $block->set_value("user_files", <<'_EOC_');
>>> defines.lua
local ffi = require "ffi"

ffi.cdef[[
    int ngx_http_lua_ffi_cert_pem_to_der(const unsigned char *pem,
        size_t pem_len, unsigned char *der, char **err);

    int ngx_http_lua_ffi_priv_key_pem_to_der(const unsigned char *pem,
        size_t pem_len, const unsigned char *passphrase,
        unsigned char *der, char **err);

    int ngx_http_lua_ffi_ssl_set_der_certificate(void *r,
        const char *data, size_t len, char **err);

    int ngx_http_lua_ffi_ssl_set_der_private_key(void *r,
        const char *data, size_t len, char **err);

    int ngx_http_lua_ffi_ssl_clear_certs(void *r, char **err);

    void *ngx_http_lua_ffi_parse_pem_cert(const unsigned char *pem,
        size_t pem_len, char **err);

    void *ngx_http_lua_ffi_parse_pem_priv_key(const unsigned char *pem,
        size_t pem_len, char **err);

    void *ngx_http_lua_ffi_parse_der_cert(const char *data, size_t len,
        char **err);

    void *ngx_http_lua_ffi_parse_der_priv_key(const char *data, size_t len,
        char **err);

    int ngx_http_lua_ffi_set_cert(void *r,
        void *cdata, char **err);

    int ngx_http_lua_ffi_set_priv_key(void *r,
        void *cdata, char **err);

    void *ngx_http_lua_ffi_get_req_ssl_pointer(void *r);

    void ngx_http_lua_ffi_free_cert(void *cdata);

    void ngx_http_lua_ffi_free_priv_key(void *cdata);

    int ngx_http_lua_ffi_ssl_verify_client(void *r, void *cdata,
        void *cdata, int depth, char **err);

    int ngx_http_lua_ffi_ssl_client_random(ngx_http_request_t *r,
        unsigned char *out, size_t *outlen, char **err);

    int ngx_http_lua_ffi_req_shared_ssl_ciphers(void *r, uint16_t *ciphers,
        uint16_t *nciphers, int filter_grease, char **err);
]]
_EOC_
    }

    my $http_config = $block->http_config || '';
    $http_config .= <<'_EOC_';
lua_package_path "$prefix/html/?.lua;../lua-resty-core/lib/?.lua;;";
_EOC_
    $block->set_value("http_config", $http_config);
});

run_tests();

__DATA__

=== TEST 1: simple cert + private key
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            require "defines"
            local ffi = require "ffi"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            ffi.C.ngx_http_lua_ffi_ssl_clear_certs(r, errmsg)

            local f = assert(io.open("t/cert/test.crt", "rb"))
            local cert = f:read("*all")
            f:close()

            local out = ffi.new("char [?]", #cert)

            local rc = ffi.C.ngx_http_lua_ffi_cert_pem_to_der(cert, #cert, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local cert_der = ffi.string(out, rc)

            local rc = ffi.C.ngx_http_lua_ffi_ssl_set_der_certificate(r, cert_der, #cert_der, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set DER cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            f = assert(io.open("t/cert/test.key", "rb"))
            local pkey = f:read("*all")
            f:close()

            out = ffi.new("char [?]", #pkey)

            local rc = ffi.C.ngx_http_lua_ffi_priv_key_pem_to_der(pkey, #pkey, nil, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            local pkey_der = ffi.string(out, rc)

            local rc = ffi.C.ngx_http_lua_ffi_ssl_set_der_private_key(r, pkey_der, #pkey_der, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set DER priv key: ",
                        ffi.string(errmsg[0]))
                return
            end
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 2: ECDSA cert + private key
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            ffi.C.ngx_http_lua_ffi_ssl_clear_certs(r, errmsg)

            local f = assert(io.open("t/cert/test_ecdsa.crt", "rb"))
            local cert = f:read("*all")
            f:close()

            local out = ffi.new("char [?]", #cert)

            local rc = ffi.C.ngx_http_lua_ffi_cert_pem_to_der(cert, #cert, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local cert_der = ffi.string(out, rc)

            local rc = ffi.C.ngx_http_lua_ffi_ssl_set_der_certificate(r, cert_der, #cert_der, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set DER cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            f = assert(io.open("t/cert/test_ecdsa.key", "rb"))
            local pkey = f:read("*all")
            f:close()

            out = ffi.new("char [?]", #pkey)

            local rc = ffi.C.ngx_http_lua_ffi_priv_key_pem_to_der(pkey, #pkey, nil, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            local pkey_der = ffi.string(out, rc)

            local rc = ffi.C.ngx_http_lua_ffi_ssl_set_der_private_key(r, pkey_der, #pkey_der, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set DER priv key: ",
                        ffi.string(errmsg[0]))
                return
            end
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test_ecdsa.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 3: Handshake continue when cert_pem_to_der errors
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local cert = "garbage data"

            local out = ffi.new("char [?]", #cert)

            local rc = ffi.C.ngx_http_lua_ffi_cert_pem_to_der(cert, #cert, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM cert: ",
                        ffi.string(errmsg[0]))
            end

            local pkey = "garbage key data"

            out = ffi.new("char [?]", #pkey)

            local rc = ffi.C.ngx_http_lua_ffi_priv_key_pem_to_der(pkey, #pkey, nil, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM priv key: ",
                        ffi.string(errmsg[0]))
            end
        }

        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"
failed to parse PEM cert: PEM_read_bio_X509_AUX()
failed to parse PEM priv key: PEM_read_bio_PrivateKey() failed

--- no_error_log
[alert]



=== TEST 4: simple cert + private key cdata
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            ffi.C.ngx_http_lua_ffi_ssl_clear_certs(r, errmsg)

            local f = assert(io.open("t/cert/test.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not cert then
                ngx.log(ngx.ERR, "failed to parse PEM cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_set_cert(r, cert, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set cdata cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(cert)

            f = assert(io.open("t/cert/test.key", "rb"))
            local pkey_data = f:read("*all")
            f:close()

            local pkey = ffi.C.ngx_http_lua_ffi_parse_pem_priv_key(pkey_data, #pkey_data, errmsg)
            if pkey == nil then
                ngx.log(ngx.ERR, "failed to parse PEM priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_set_priv_key(r, pkey, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set cdata priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_priv_key(pkey)
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 5: ECDSA cert + private key cdata
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            ffi.C.ngx_http_lua_ffi_ssl_clear_certs(r, errmsg)

            local f = assert(io.open("t/cert/test_ecdsa.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not cert then
                ngx.log(ngx.ERR, "failed to parse PEM cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_set_cert(r, cert, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set cdata cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(cert)

            f = assert(io.open("t/cert/test_ecdsa.key", "rb"))
            local pkey_data = f:read("*all")
            f:close()

            local pkey = ffi.C.ngx_http_lua_ffi_parse_pem_priv_key(pkey_data, #pkey_data, errmsg)
            if pkey == nil then
                ngx.log(ngx.ERR, "failed to parse PEM priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_set_priv_key(r, pkey, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set cdata priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_priv_key(pkey)
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test_ecdsa.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 6: verify client with CA certificates
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            require "defines"
            local ffi = require "ffi"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local f = assert(io.open("t/cert/test.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local client_cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not client_cert then
                ngx.log(ngx.ERR, "failed to parse PEM client cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_ssl_verify_client(r, client_cert, nil, 1, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to verify client: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(client_cert)
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        location / {
            default_type 'text/plain';
            content_by_lua_block {
                print('client certificate subject: ', ngx.var.ssl_client_s_dn)
                ngx.say(ngx.var.ssl_client_verify)
            }
            more_clear_headers Date;
        }
    }
--- config
    location /t {
        proxy_pass                  https://unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        proxy_ssl_certificate       ../../cert/test.crt;
        proxy_ssl_certificate_key   ../../cert/test.key;
        proxy_ssl_session_reuse     off;
    }

--- request
GET /t
--- response_body
SUCCESS

--- error_log
client certificate subject: emailAddress=agentzh@gmail.com,CN=test.com

--- no_error_log
[error]
[alert]



=== TEST 7: verify client without CA certificates
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            require "defines"
            local ffi = require "ffi"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_ssl_verify_client(r, nil, nil, -1, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to verify client: ",
                        ffi.string(errmsg[0]))
                return
            end
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        location / {
            default_type 'text/plain';
            content_by_lua_block {
                print('client certificate subject: ', ngx.var.ssl_client_s_dn)
                ngx.say(ngx.var.ssl_client_verify)
            }
            more_clear_headers Date;
        }
    }
--- config
    location /t {
        proxy_pass                  https://unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        proxy_ssl_certificate       ../../cert/test.crt;
        proxy_ssl_certificate_key   ../../cert/test.key;
        proxy_ssl_session_reuse     off;
    }

--- request
GET /t
--- response_body eval
qr/FAILED:self[- ]signed certificate/

--- error_log
client certificate subject: emailAddress=agentzh@gmail.com,CN=test.com

--- no_error_log
[error]
[alert]



=== TEST 8: verify client but client provides no certificate
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            require "defines"
            local ffi = require "ffi"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local f = assert(io.open("t/cert/test.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local client_cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not client_cert then
                ngx.log(ngx.ERR, "failed to parse PEM client cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_ssl_verify_client(r, client_cert, nil, 1, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to verify client: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(client_cert)
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        location / {
            default_type 'text/plain';
            content_by_lua_block {
                print('client certificate subject: ', ngx.var.ssl_client_s_dn)
                ngx.say(ngx.var.ssl_client_verify)
            }
            more_clear_headers Date;
        }
    }
--- config
    location /t {
        proxy_pass                  https://unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        proxy_ssl_session_reuse     off;
    }

--- request
GET /t
--- response_body
NONE

--- error_log
client certificate subject: nil

--- no_error_log
[error]
[alert]



=== TEST 9: simple cert + private key with passphrase
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"

            ffi.cdef[[
                int ngx_http_lua_ffi_cert_pem_to_der(const unsigned char *pem,
                    size_t pem_len, unsigned char *der, char **err);

                int ngx_http_lua_ffi_priv_key_pem_to_der(const unsigned char *pem,
                    size_t pem_len, const unsigned char *passphrase,
                    unsigned char *der, char **err);

                int ngx_http_lua_ffi_ssl_set_der_certificate(void *r,
                    const char *data, size_t len, char **err);

                int ngx_http_lua_ffi_ssl_set_der_private_key(void *r,
                    const char *data, size_t len, char **err);

                int ngx_http_lua_ffi_ssl_clear_certs(void *r, char **err);
            ]]

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if not r then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            ffi.C.ngx_http_lua_ffi_ssl_clear_certs(r, errmsg)

            local f = assert(io.open("t/cert/test_passphrase.crt", "rb"))
            local cert = f:read("*all")
            f:close()

            local out = ffi.new("char [?]", #cert)

            local rc = ffi.C.ngx_http_lua_ffi_cert_pem_to_der(cert, #cert, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local cert_der = ffi.string(out, rc)

            local rc = ffi.C.ngx_http_lua_ffi_ssl_set_der_certificate(r, cert_der, #cert_der, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set DER cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            f = assert(io.open("t/cert/test_passphrase.key", "rb"))
            local pkey = f:read("*all")
            f:close()

            local passphrase = "123456"

            out = ffi.new("char [?]", #pkey)

            local rc = ffi.C.ngx_http_lua_ffi_priv_key_pem_to_der(pkey, #pkey, passphrase, out, errmsg)
            if rc < 1 then
                ngx.log(ngx.ERR, "failed to parse PEM priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            local pkey_der = ffi.string(out, rc)

            local rc = ffi.C.ngx_http_lua_ffi_ssl_set_der_private_key(r, pkey_der, #pkey_der, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set DER priv key: ",
                        ffi.string(errmsg[0]))
                return
            end
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test_passphrase.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", false)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to recieve response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 10: Raw SSL pointer
--- skip_eval: 8:$ENV{TEST_NGINX_USE_BORINGSSL}
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local r = require "resty.core.base" .get_request()
            if not r then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local ssl = ffi.C.ngx_http_lua_ffi_get_req_ssl_pointer(r);
            if ssl == nil then
                ngx.log(ngx.ERR, "failed to retrieve SSL*")
                return
            end

            ffi.cdef[[
                const char *SSL_get_servername(const void *, const int);
            ]]
            local TLSEXT_NAMETYPE_host_name = 0
            local sni = ffi.C.SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name)
            if sni == nil then
                ngx.log(ngx.ERR, "failed to get sni")
                return
            end

            ngx.log(ngx.INFO, "SNI is ", ffi.string(sni))
        }

        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
SNI is test.com

--- no_error_log
[error]
[alert]



=== TEST 11: DER cert + private key cdata
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            ffi.C.ngx_http_lua_ffi_ssl_clear_certs(r, errmsg)

            local f = assert(io.open("t/cert/test_der.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local cert = ffi.C.ngx_http_lua_ffi_parse_der_cert(cert_data, #cert_data, errmsg)
            if not cert then
                ngx.log(ngx.ERR, "failed to parse DER cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_set_cert(r, cert, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set cdata cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(cert)

            f = assert(io.open("t/cert/test_der.key", "rb"))
            local pkey_data = f:read("*all")
            f:close()

            local pkey = ffi.C.ngx_http_lua_ffi_parse_der_priv_key(pkey_data, #pkey_data, errmsg)
            if pkey == nil then
                ngx.log(ngx.ERR, "failed to parse DER priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_set_priv_key(r, pkey, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to set cdata priv key: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_priv_key(pkey)
        }

        ssl_certificate ../../cert/test2.crt;
        ssl_certificate_key ../../cert/test2.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 12: client random
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   test.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            local ffi = require "ffi"
            require "defines"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            -- test client random length
            local out = ffi.new("unsigned char[?]", 0)
            local sizep = ffi.new("size_t[1]", 0)
			
            local rc = ffi.C.ngx_http_lua_ffi_ssl_client_random(r, out, sizep, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to get client random length: ",
                        ffi.string(errmsg[0]))
                return
            end

            if tonumber(sizep[0]) ~= 32 then
                ngx.log(ngx.ERR, "client random length does not equal 32")
                return
            end

            -- test client random value
            out = ffi.new("unsigned char[?]", 50)
            sizep = ffi.new("size_t[1]", 50)

            rc = ffi.C.ngx_http_lua_ffi_ssl_client_random(r, out, sizep, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to get client random: ",
                        ffi.string(errmsg[0]))
                return
            end

            local init_v = "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
            if ffi.string(out, sizep[0]) == init_v then
                ngx.log(ngx.ERR, "maybe the client random value is incorrect")
                return
            end
        }

        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;

        server_tokens off;
        location /foo {
            default_type 'text/plain';
            content_by_lua_block { ngx.status = 201 ngx.say("foo") ngx.exit(201) }
            more_clear_headers Date;
        }
    }
--- config
    server_tokens off;
    lua_ssl_trusted_certificate ../../cert/test.crt;

    location /t {
        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(2000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(nil, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                local req = "GET /foo HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n"
                local bytes, err = sock:send(req)
                if not bytes then
                    ngx.say("failed to send http request: ", err)
                    return
                end

                ngx.say("sent http request: ", bytes, " bytes.")

                while true do
                    local line, err = sock:receive()
                    if not line then
                        -- ngx.say("failed to receive response status line: ", err)
                        break
                    end

                    ngx.say("received: ", line)
                end

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
            -- collectgarbage()
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: cdata
sent http request: 56 bytes.
received: HTTP/1.1 201 Created
received: Server: nginx
received: Content-Type: text/plain
received: Content-Length: 4
received: Connection: close
received: 
received: foo
close: 1 nil

--- error_log
lua ssl server name: "test.com"

--- no_error_log
[error]
[alert]



=== TEST 13: verify client, but server don't trust root ca
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   example.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            require "defines"
            local ffi = require "ffi"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local f = assert(io.open("t/cert/mtls_server.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local client_cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not client_cert then
                ngx.log(ngx.ERR, "failed to parse PEM client cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_ssl_verify_client(r, client_cert, nil, 2, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to verify client: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(client_cert)
        }

        ssl_certificate ../../cert/mtls_server.crt;
        ssl_certificate_key ../../cert/mtls_server.key;

        location / {
            default_type 'text/plain';
            content_by_lua_block {
                ngx.say(ngx.var.ssl_client_verify)
            }
            more_clear_headers Date;
        }
    }
--- config
    location /t {
        proxy_pass                  https://unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        proxy_ssl_certificate       ../../cert/mtls_client.crt;
        proxy_ssl_certificate_key   ../../cert/mtls_client.key;
        proxy_ssl_session_reuse     off;
    }

--- request
GET /t
--- response_body
FAILED:unable to verify the first certificate

--- no_error_log
[error]
[alert]



=== TEST 14: verify client and server trust root ca
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name   example.com;

        ssl_certificate_by_lua_block {
            collectgarbage()

            require "defines"
            local ffi = require "ffi"

            local errmsg = ffi.new("char *[1]")

            local r = require "resty.core.base" .get_request()
            if r == nil then
                ngx.log(ngx.ERR, "no request found")
                return
            end

            local f = assert(io.open("t/cert/mtls_server.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local client_cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not client_cert then
                ngx.log(ngx.ERR, "failed to parse PEM client cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local f = assert(io.open("t/cert/mtls_ca.crt", "rb"))
            local cert_data = f:read("*all")
            f:close()

            local trusted_cert = ffi.C.ngx_http_lua_ffi_parse_pem_cert(cert_data, #cert_data, errmsg)
            if not trusted_cert then
                ngx.log(ngx.ERR, "failed to parse PEM trusted cert: ",
                        ffi.string(errmsg[0]))
                return
            end

            local rc = ffi.C.ngx_http_lua_ffi_ssl_verify_client(r, cert, trusted_cert, 2, errmsg)
            if rc ~= 0 then
                ngx.log(ngx.ERR, "failed to verify client: ",
                        ffi.string(errmsg[0]))
                return
            end

            ffi.C.ngx_http_lua_ffi_free_cert(client_cert)
            ffi.C.ngx_http_lua_ffi_free_cert(trusted_cert)
        }

        ssl_certificate ../../cert/mtls_server.crt;
        ssl_certificate_key ../../cert/mtls_server.key;

        location / {
            default_type 'text/plain';
            content_by_lua_block {
                ngx.say(ngx.var.ssl_client_verify)
            }
            more_clear_headers Date;
        }
    }
--- config
    location /t {
        proxy_pass                  https://unix:$TEST_NGINX_HTML_DIR/nginx.sock;
        proxy_ssl_certificate       ../../cert/mtls_client.crt;
        proxy_ssl_certificate_key   ../../cert/mtls_client.key;
        proxy_ssl_session_reuse     off;
    }

--- request
GET /t
--- response_body
SUCCESS

--- no_error_log
[error]
[alert]



=== TEST 15: Get supported ciphers
--- skip_eval: 8:$ENV{TEST_NGINX_USE_BORINGSSL}
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;
        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;
        ssl_protocols TLSv1.2;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;

        server_tokens off;  
        
        location /ciphers { 
            content_by_lua_block {
                require "defines"
                local ffi = require "ffi"
                local cjson = require "cjson.safe"
                local base = require "resty.core.base"
                local get_request = base.get_request

                local MAX_CIPHERS = 64
                local ciphers = ffi.new("uint16_t[?]", MAX_CIPHERS)
                local nciphers = ffi.new("uint16_t[1]", MAX_CIPHERS)
                local err = ffi.new("char*[1]")

                local r = get_request()
                local ret = ffi.C.ngx_http_lua_ffi_req_shared_ssl_ciphers(r, ciphers, nciphers, 0, err)

                if ret ~= 0 then
                    ngx.log(ngx.ERR, "error: ", ffi.string(err[0]))
                    return
                end

                local res = {}
                for i = 0, nciphers[0] - 1 do
                    local cipher_id = string.format("%04x", ciphers[i])
                    table.insert(res, cipher_id)
                end

                ngx.say(cjson.encode(res))
            }
        }
    }
--- config
    server_tokens off;
    location /t {
        proxy_ssl_protocols TLSv1.2;
        proxy_ssl_session_reuse     off;        
        proxy_ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256;
        proxy_pass https://unix:$TEST_NGINX_HTML_DIR/nginx.sock:/ciphers;
    }
--- request
GET /t
--- response_body_like
\["c02f","c02b"\]
--- error_log chomp
TLSv1.2, cipher: "ECDHE-RSA-AES128-GCM-SHA256 TLSv1.2 Kx=ECDH Au=RSA Enc=AESGCM(128) Mac=AEAD"



=== TEST 16: SSL cipher API error handling (no SSL)
--- skip_eval: 8:$ENV{TEST_NGINX_USE_BORINGSSL}
--- config
    location /t {
        content_by_lua_block {
            require "defines"        
            local ffi = require "ffi"
            
            local ciphers = ffi.new("uint16_t[64]")
            local nciphers = ffi.new("uint16_t[1]", 64)
            local err = ffi.new("char*[1]")

            -- use nil request to trigger error
            local ret = ffi.C.ngx_http_lua_ffi_req_shared_ssl_ciphers(nil, ciphers, nciphers, 0, err)

            ngx.say("ret: ", ret)
            if err[0] ~= nil then
                ngx.say("err: ", ffi.string(err[0]))
            end
        }
    }
--- request
GET /t
--- response_body
ret: -1
err: bad request

--- no_error_log
[error]
[alert]



=== TEST 17: Buffer overflow handling
--- skip_eval: 8:$ENV{TEST_NGINX_USE_BORINGSSL}
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;
        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;
        ssl_protocols TLSv1.2;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;

        server_tokens off;  

        
        location /ciphers { 
            content_by_lua_block {
                require "defines"            
                local ffi = require "ffi"
                local base = require "resty.core.base"
                local get_request = base.get_request
                local cjson = require "cjson.safe"
    
                local MAX_CIPHERS = 64
                local ciphers = ffi.new("uint16_t[?]", MAX_CIPHERS)
                local nciphers = ffi.new("uint16_t[1]", MAX_CIPHERS)
                local err = ffi.new("char*[1]")

                local r = get_request()
                local ret = ffi.C.ngx_http_lua_ffi_req_shared_ssl_ciphers(r, ciphers, nciphers, 0, err)

                if ret ~= 0 then
                    ngx.log(ngx.ERR, "error: ", ffi.string(err[0]))
                    return
                end
                local res = {}
                for i = 0, nciphers[0] - 1 do
                    local cipher_id = string.format("%04x", ciphers[i])

                    table.insert(res, cipher_id)
                end
                ngx.say(cjson.encode(res))
            }
        }
    }
--- config
    server_tokens off;
    location /t {
        proxy_ssl_protocols TLSv1.2;
        proxy_ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256;
        proxy_ssl_session_reuse off;    
        proxy_pass https://unix:$TEST_NGINX_HTML_DIR/nginx.sock:/ciphers;
    }
--- request
GET /t
--- response_body_like
\["c02f"\]
--- error_code: 200
--- error_log chomp
TLSv1.2, cipher: "ECDHE-RSA-AES128-GCM-SHA256 TLSv1.2 Kx=ECDH Au=RSA Enc=AESGCM(128) Mac=AEAD"



=== TEST 18: BORINGSSL error handling
--- skip_eval: 8:$ENV{TEST_NGINX_USE_OPENSSL}
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;
        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;

        server_tokens off;  

        
        location /ciphers { 
            content_by_lua_block {
                require "defines"            
                local ffi = require "ffi"
                local base = require "resty.core.base"
                local get_request = base.get_request

                local MAX_CIPHERS = 64
                local ciphers = ffi.new("uint16_t[?]", MAX_CIPHERS)
                local nciphers = ffi.new("uint16_t[1]", MAX_CIPHERS)
                local err = ffi.new("char*[1]")

                local r = get_request()
                local ret = ffi.C.ngx_http_lua_ffi_req_shared_ssl_ciphers(r, ciphers, nciphers, 0, err)

                if ret ~= 0 then
                    ngx.say("Error: ", ffi.string(err[0]))
                    return
                end
            
            }
        }              
    }
--- config
    server_tokens off;
    location /t {
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256;
        proxy_pass https://unix:$TEST_NGINX_HTML_DIR/nginx.sock:/ciphers;
    }
--- request
GET /t
--- response_body_like chomp
Error: BoringSSL is not supported for SSL cipher operations
--- error_code: 200

--- no_error_log
[error]
[alert]



=== TEST 19: Get supported ciphers with GREASE filtering
--- skip_eval: 8:$ENV{TEST_NGINX_USE_BORINGSSL}
--- http_config
    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;
        ssl_certificate ../../cert/test.crt;
        ssl_certificate_key ../../cert/test.key;
        ssl_protocols TLSv1.2;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;

        server_tokens off;
        
        location /ciphers {
            content_by_lua_block {
                require "defines"
                local ffi = require "ffi"
                local cjson = require "cjson.safe"
                local base = require "resty.core.base"
                local get_request = base.get_request

                local MAX_CIPHERS = 64
                local ciphers = ffi.new("uint16_t[?]", MAX_CIPHERS)
                local nciphers = ffi.new("uint16_t[1]", MAX_CIPHERS)
                local err = ffi.new("char*[1]")

                local r = get_request()
                -- Test without GREASE filtering
                local ret = ffi.C.ngx_http_lua_ffi_req_shared_ssl_ciphers(r, ciphers, nciphers, 0, err)
                if ret ~= 0 then
                    ngx.log(ngx.ERR, "error without filtering: ", ffi.string(err[0]))
                    return
                end

                local res_no_filter = {}
                for i = 0, nciphers[0] - 1 do
                    local cipher_id = string.format("%04x", ciphers[i])
                    table.insert(res_no_filter, cipher_id)
                end

                -- Reset buffers
                nciphers[0] = MAX_CIPHERS
                
                -- Test with GREASE filtering
                local ret = ffi.C.ngx_http_lua_ffi_req_shared_ssl_ciphers(r, ciphers, nciphers, 1, err)
                if ret ~= 0 then
                    ngx.log(ngx.ERR, "error with filtering: ", ffi.string(err[0]))
                    return
                end

                local res_with_filter = {}
                for i = 0, nciphers[0] - 1 do
                    local cipher_id = string.format("%04x", ciphers[i])
                    table.insert(res_with_filter, cipher_id)
                end

                ngx.say("without_filter:", cjson.encode(res_no_filter))
                ngx.say("with_filter:", cjson.encode(res_with_filter))
            }
        }
    }
--- config
    server_tokens off;
    location /t {
        proxy_ssl_protocols TLSv1.2;
        proxy_ssl_session_reuse     off;
        proxy_ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256;
        proxy_pass https://unix:$TEST_NGINX_HTML_DIR/nginx.sock:/ciphers;
    }
--- request
GET /t
--- response_body_like
without_filter:\[.*\]
with_filter:\[.*\]
--- error_log chomp
TLSv1.2, cipher: "ECDHE-RSA-AES128-GCM-SHA256 TLSv1.2 Kx=ECDH Au=RSA Enc=AESGCM(128) Mac=AEAD"
