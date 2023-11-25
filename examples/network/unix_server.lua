#!/usr/bin/env eco

local socket = require 'eco.socket'
local sys = require 'eco.sys'

sys.signal(sys.SIGINT, function()
    print('\nGot SIGINT, now quit')
    eco.unloop()
end)

local function handle_client(c)
    while true do
        local data, err = c:recv(100)
        if not data then
            print(err)
            c:close()
            break
        end
        print('read:', data)
        c:send('I am eco:' .. data)
    end
end

local s, err = socket.listen_unix('/tmp/eco.sock')
if not s then
    error(err)
end

print('listen...')

while true do
    local c, peer = s:accept()
    if not c then
        print(peer)
        break
    end

    print('new connection:', peer.path)
    eco.run(handle_client, c)
end
