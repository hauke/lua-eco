-- SPDX-License-Identifier: MIT
-- Author: Jianhui Zhao <zhaojh329@gmail.com>

local file = require 'eco.core.file'
local socket = require 'eco.socket'
local essl = require 'eco.core.ssl'
local sys = require 'eco.core.sys'

local SSL_MT_SERVER = 0
local SSL_MT_CLIENT = 1
local SSL_MT_ESTAB  = 2

local M = {}

local function ssl_close(ssock)
    if ssock.__closed then
        return
    end

    ssock.ssl:free()

    if ssock.name ~= SSL_MT_ESTAB then
        ssock.ctx:free()
    end

    ssock.sock:close()
    ssock.__closed = true
end

local function ssl_socket(ssock)
    return ssock.sock
end

local client_methods = {
    close = ssl_close,
    socket = ssl_socket
}

local metatable_cli = { __index = client_methods, __gc = ssl_close }

-- Set the timeout value in seconds for subsequent socket operations
function client_methods:settimeout(seconds)
    self.timeout = seconds
end

function client_methods:closed()
    return self.__closed
end

function client_methods:send(data)
    if self.__closed then
        return nil, 'closed'
    end

    local ssl, iow, ior = self.ssl, self.iow, self.ior
    local w = iow

    local total = #data
    local sent = 0
    local ok, n, err, errs

    while sent < total do
        ok, err = w:wait()
        if not ok then
            return nil, err, sent
        end

        n, err, errs = ssl:write(data:sub(sent + 1))
        if not n then
            if err == essl.ERROR then
                return nil, errs, sent
            end

            w = err == essl.WANT_READ and ior or iow
        end
        sent = sent + n
    end

    return sent
end

function client_methods:sendfile(fd, count, offset)
    if self.__closed then
        return nil, 'closed'
    end

    local st, err = file.fstat(fd)
    if not st then
        return false, err
    end

    count = count or st.size

    if offset then
        offset, err = file.lseek(fd, offset, file.SEEK_SET)
        if not offset then
            return nil, err
        end
    end

    local chunk = 4096
    local sent = 0
    local data

    while count > 0 do
        data, err = file.read(fd, chunk > count and count or chunk)
        if not data then
            break
        end

        if #data == 0 then
            break
        end

        _, err = self:send(data)
        if err then
            break
        end

        sent = sent + #data
        count = count - #data
    end

    if err then
        return nil, err
    end

    return sent
end

local function ssl_wait(err, ior, iow, timeout)
    local w = err == essl.WANT_READ and ior or iow
    return w:wait(timeout)
end

function client_methods:recv(n)
    if self.__closed then
        return nil, 'closed'
    end

    local ior, iow = self.ior, self.iow
    local ssl = self.ssl

    while true do
        local data, err, errs = ssl:read(n)
        if not data then
            if err == essl.ERROR then
                return nil, errs
            end

            if not ssl_wait(err, ior, iow, self.timeout) then
                return nil, 'timeout'
            end
        else
            if #data == 0 then
                return nil, 'closed'
            end

            return data
        end
    end
end

local function ssl_negotiate(ssock, deadtime)
    local ssl, iow, ior = ssock.ssl, ssock.iow, ssock.ior
    local ok, err, errs

    while true do
        ok, err, errs = ssl:negotiate()
        if ok then
            return true
        end

        if err == essl.ERROR or err == essl.INSECURE then
            return false, errs
        end

        if not ssl_wait(err, ior, iow, deadtime - sys.uptime()) then
            return nil, 'handshake timeout'
        end
    end
end

local function ssl_setmetatable(ctx, sock, mt, name, insecure)
    local fd = sock:getfd()

    local ssock = {
        name = name,
        fd = fd,
        ctx = ctx,
        sock = sock,
        ior = eco.watcher(eco.IO, fd)
    }

    setmetatable(ssock, mt)

    if name == SSL_MT_SERVER then
        return ssock
    else
        ssock.ssl = ctx:new(fd, insecure)
        ssock.iow = eco.watcher(eco.IO, fd, eco.WRITE)
    end

    local ok, err = ssl_negotiate(ssock, sys.uptime() + 3.0)
    if not ok then
        return nil, err
    end

    return ssock
end

local server_methods = {
    close = ssl_close,
    socket = ssl_socket
}

local metatable_srv = { __index = server_methods, __gc = ssl_close }

function server_methods:accept()
    local sock, addr = self.sock:accept()
    if not sock then
        return nil, addr
    end

    local ssock, err = ssl_setmetatable(self.ctx, sock, metatable_cli, SSL_MT_ESTAB)
    if not ssock then
        sock:close()
        return nil, err
    end

    return ssock, addr
end

function M.listen(ipaddr, port, options, ipv6)
    assert(type(options) == 'table' and options.cert and options.key)

    local ctx = essl.context(true)

    if options.ca then
        if not ctx:load_ca_cert_file(options.ca) then
            return nil, 'load ca cert file fail'
        end
    end

    if not ctx:load_cert_file(options.cert) then
        return nil, 'load cert file fail'
    end

    if not ctx:load_key_file(options.key) then
        return nil, 'load key file fail'
    end

    local listen = socket.listen_tcp

    if ipv6 then
        listen = socket.listen_tcp6
    end

    local sock, err = listen(ipaddr, port, options)
    if not sock then
        return nil, err
    end

    return ssl_setmetatable(ctx, sock, metatable_srv, SSL_MT_SERVER)
end

function M.listen6(ipaddr, port, options)
    return M.listen(ipaddr, port, options, true)
end

local function ssl_connect(ipaddr, port, insecure, ipv6)
    local connect = socket.connect_tcp

    if ipv6 then
        connect = socket.connect_tcp6
    end

    local sock, err = connect(ipaddr, port)
    if not sock then
        return nil, err
    end

    local ctx = essl.context(false)

    local ssock, err = ssl_setmetatable(ctx, sock, metatable_cli, SSL_MT_CLIENT, insecure)
    if not ssock then
        sock:close()
        return nil, err
    end

    return ssock
end

function M.connect(ipaddr, port, insecure)
    return ssl_connect(ipaddr, port, insecure)
end

function M.connect6(ipaddr, port, insecure)
    return ssl_connect(ipaddr, port, insecure, true)
end

function M.create_bufio_fill(self)
    local ior, iow = self.ior, self.iow
    local ssl = self.ssl

    return function(b)
        if self.eof then return nil, 'closed' end

        while true do
            local r, err, errs = ssl:readto(b:tail(), b:room())
            if not r then
                if err == essl.ERROR then
                    return nil, errs
                end

                if not ssl_wait(err, ior, iow, b.timeout) then
                    return nil, 'timeout'
                end
            else
                if r == 0 then
                    b.eof = true
                    b.eof_err = 'closed'
                    return nil, 'closed'
                end

                b:add(r)

                return r
            end
        end
    end
end

return M
