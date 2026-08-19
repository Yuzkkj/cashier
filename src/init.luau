local client = require(script.CashierClient)
local server = require(script.CashierServer)

export type Client = client.CashierClient
export type Server = server.CashierServer

return {
	client = client,
	server = server,
}
