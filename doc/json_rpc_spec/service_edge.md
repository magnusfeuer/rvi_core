# RVI - SERVICE EDGE API

# PURPOSE

# ACCEPTED JSON-RPC CALLS

## message - Submit a fire-and-forget message


The ```message``` JSON-RPC call allows a locally connected service to submit a
JSON payload to be delivered to another local or remote service.

The message will be delivered using best efforts within a given time
interval. If the message cannot be delivered with the timeout period,
it will silently be dropped.


### Example

    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "message",
        "params": {
			"timeout" : 5000,
			"service": "jlr.com/vin/123456/control/lock",
			"action": "lock",
			"locks": [ "r1_lt", "r2_rt", "trunk" ]
		}
    }
	



### Parameters

**```timeout```**<br>
Test




### Return values

