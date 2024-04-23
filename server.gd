extends Node

const DEFAULT_PORT : int = 8382

# TODO upgrade to work with multiple peers & requests at once
const DEFAULT_MAX_PEERS : int = 1

# Regtest ports:
#const MAINCHAIN_RPC_PORT = 18443
#const TESTCHAIN_RPC_PORT = 18743

const MAINCHAIN_RPC_PORT : int = 8332
const TESTCHAIN_RPC_PORT : int = 8272
const BITASSETS_RPC_PORT : int = 19005
const BITNAMES_RPC_PORT : int = 19020
const THUNDER_RPC_PORT : int = 1910

const RPC_USER_DEFAULT : String = "user"
const RPC_PASS_DEFAULT : String = "password"

var rpc_user : String = ""
var rpc_pass : String = ""

var peers = []
var pending_requests = []

var chain_names = []

var mainchain_balance : float = 0.0

# TODO store responses from $HTTPRequestGetTestchainAddress and
# $HTTPRequestSendToAddressMainchain etc inside of the relevant member of 
# pending_requests instead of here
# Tempory storage of RPC request results
var testchain_address : String = ""
var testchain_payment_transaction : Dictionary
var bitassets_address : String = ""
var bitassets_payment_transaction : Dictionary
var thunder_address : String = ""
var thunder_payment_transaction : Dictionary
var mainchain_payout_txid : String = ""

signal mainchain_balance_updated
signal mainchain_sendtoaddress_txid_result
signal generated_testchain_address
signal received_testchain_transaction_result
signal generated_bitassets_address
signal received_bitassets_transaction_result
signal generated_thunder_address
signal received_thunder_transaction_result

@onready var http_rpc_mainchain_getbalance: HTTPRequest = $HTTPRequestGetBalanceMainchain 
@onready var http_rpc_mainchain_sendtoaddress: HTTPRequest = $HTTPRequestSendToAddressMainchain
@onready var http_rpc_testchain_getnewaddress: HTTPRequest = $HTTPRequestGetTestchainAddress
@onready var http_rpc_testchain_gettransaction: HTTPRequest = $HTTPRequestGetTestchainTransaction
@onready var http_rpc_bitassets_getnewaddress: HTTPRequest = $HTTPRequestGetBitAssetsAddress
@onready var http_rpc_bitassets_gettransaction: HTTPRequest = $HTTPRequestBitAssetsTransaction
@onready var http_rpc_thunder_getnewaddress: HTTPRequest = $HTTPRequestGetThunderAddress
@onready var http_rpc_thunder_gettransaction: HTTPRequest = $HTTPRequestGetThunderTransaction


func _ready() -> void:
	print("Starting server")
	
	chain_names = [
		$"/root/Net".CHAIN_NAME_TESTCHAIN,
		$"/root/Net".CHAIN_NAME_BITASSETS,
		$"/root/Net".CHAIN_NAME_THUNDER,
	]
	
	# Read rpcuser and password
	var arguments : Dictionary = {}
	for argument in OS.get_cmdline_user_args():
		if argument.find("=") > -1:
			var key_value = argument.split("=")
			arguments[key_value[0].lstrip("--")] = key_value[1]
		else:
			arguments[argument.lstrip("--")] = ""
			
	if not arguments.has("rpcuser") or not arguments.has("rpcpassword"):
		print(" -- --rpcuser=user --rpcpassword=password required!")
		print("Will use default rpcuser=user and rpcpassword=password")
		rpc_user = RPC_USER_DEFAULT
		rpc_pass = RPC_PASS_DEFAULT
	else:
		rpc_user = arguments["rpcuser"]
		rpc_pass = arguments["rpcpassword"]
		
	print("using rpc credential : ", rpc_user, ":", rpc_pass)
	
	$"/root/Net".fast_withdraw_requested.connect(_on_fast_withdraw_requested)
	$"/root/Net".fast_withdraw_invoice_paid.connect(_on_fast_withdraw_invoice_paid)
	
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	
	# Create server
	var peer = ENetMultiplayerPeer.new()
	peer.create_server(DEFAULT_PORT, DEFAULT_MAX_PEERS)
	multiplayer.multiplayer_peer = peer

	print("Server started with peer ID: ", peer.get_unique_id())


func _on_peer_connected(id : int) -> void:
	print("Peer connected!")
	peers.push_back(id)


func _on_peer_disconnected(id : int) -> void:
	print("Peer Disconnected!")
	peers.erase(id)


# TODO make this work asynchronously - remove await
func _on_fast_withdraw_requested(peer_id : int, chain_name : String, amount : float, destination: String) -> void:	
	print("Server began handling fast withdraw request")
	print("Peer: ", peer_id)
	print("Chain: ", chain_name)
	print("Amount: ", amount)
	print("Mainchain destination: ", destination)
	
	if chain_name not in chain_names:
		print("Invalid chain name!")
		return	
		
	rpc_mainchain_getbalance()
	await mainchain_balance_updated
	
	print("Mainchain balance: ", mainchain_balance)
	
	# Check our mainchain balance is enough
	if mainchain_balance < amount:
		printerr("Insufficient mainchain balance for trade!")
		return
	
	# Get a new sidechain address for specified sidechain
	if chain_name == $"/root/Net".CHAIN_NAME_TESTCHAIN:
		rpc_testchain_getnewaddress()
		await generated_testchain_address
		
		print("New testchain address generated for trade invoice: ", testchain_address)
	
		# Create and store invoice, send instructions to client for completion
		pending_requests.push_back([peer_id, testchain_address, amount, destination])
		print("Sending invoice to requesting peer")
		$"/root/Net".receive_fast_withdraw_invoice.rpc_id(peer_id, amount, testchain_address)
	
	elif chain_name == $"/root/Net".CHAIN_NAME_BITASSETS:
		rpc_bitassets_getnewaddress()
		await generated_bitassets_address
		
		print("New bitassets address generated for trade invoice: ", bitassets_address)
	
		# Create and store invoice, send instructions to client for completion
		pending_requests.push_back([peer_id, bitassets_address, amount, destination])
		print("Sending invoice to requesting peer")
		$"/root/Net".receive_fast_withdraw_invoice.rpc_id(peer_id, amount, bitassets_address)

		
	elif chain_name == $"/root/Net".CHAIN_NAME_THUNDER:
		rpc_thunder_getnewaddress()
		await generated_thunder_address
		
		print("New thunder address generated for trade invoice: ", thunder_address)
	
		# Create and store invoice, send instructions to client for completion
		pending_requests.push_back([peer_id, thunder_address, amount, destination])
		print("Sending invoice to requesting peer")
		$"/root/Net".receive_fast_withdraw_invoice.rpc_id(peer_id, amount, thunder_address)


# TODO make this work asynchronously - remove await
func _on_fast_withdraw_invoice_paid(peer_id : int, chain_name : String, txid : String, amount : float, destination: String) -> void:
	print("Client claims to have paid invoice")
	print("Peer: ", peer_id)
	print("Chain: ", chain_name)
	print("TxID: ", txid)
	print("Amount: ", amount)
	print("Mainchain destination: ", destination)
	
	if chain_name not in chain_names:
		print("Invalid chain name!")
		return
	
	# Lookup invoice
	# TODO change containers improve lookup - test only
	var invoice_paid = null
	for invoice in pending_requests:
		if invoice[0] == peer_id && invoice[2] == amount && invoice[3] == destination:
			invoice_paid = invoice
			break
	
	if invoice_paid == null:
		printerr("No matching invoice found!")
		return
	
	# Check if paid
	
	if chain_name == $"/root/Net".CHAIN_NAME_TESTCHAIN:
		testchain_payment_transaction.clear()
		rpc_testchain_gettransaction(txid)
		await received_testchain_transaction_result
	
		if testchain_payment_transaction.is_empty():
			printerr("No testchain payment transaction found!")
			return
			
		# Verify that transaction paid invoice amount to our L2 address
		var payment_found : bool = false
		for output in testchain_payment_transaction["details"]:
			print("Output:",  output)
			if output["address"] == testchain_address and output["amount"] >= invoice_paid[2]:
				payment_found = true
				break
				
		if not payment_found:
			printerr("Payment not found in transaction!")
			return
	
	elif chain_name == $"/root/Net".CHAIN_NAME_BITASSETS:
		bitassets_payment_transaction.clear()
		rpc_bitassets_gettransaction(txid)
		await received_bitassets_transaction_result
	
		if bitassets_payment_transaction.is_empty():
			printerr("No bitassets payment transaction found!")
			return
			
		var payment_found : bool = false
		for output in bitassets_payment_transaction["details"]:
			print("Output:",  output)
			if output["address"] == bitassets_address and output["amount"] >= invoice_paid[2]:
				payment_found = true
				break
				
		if not payment_found:
			printerr("Payment not found in transaction!")
			return
			
	elif chain_name == $"/root/Net".CHAIN_NAME_THUNDER:
		thunder_payment_transaction.clear()
		rpc_thunder_gettransaction(txid)
		await received_thunder_transaction_result
	
		if thunder_payment_transaction.is_empty():
			printerr("No thunder payment transaction found!")
			return
			
		var payment_found : bool = false
		for output in thunder_payment_transaction["details"]:
			print("Output:",  output)
			if output["address"] == thunder_address and output["amount"] >= invoice_paid[2]:
				payment_found = true
				break
				
		if not payment_found:
			printerr("Payment not found in transaction!")
			return

	# Pay client peer and erase invoice
	
	rpc_mainchain_sendtoaddress(amount, destination)
	await mainchain_sendtoaddress_txid_result
	
	pending_requests.erase(invoice_paid)
	
	$"/root/Net".withdraw_complete.rpc_id(peer_id, mainchain_payout_txid, amount, destination)
	

func rpc_mainchain_getbalance() -> void:
	make_rpc_request(MAINCHAIN_RPC_PORT, "getbalance", [], http_rpc_mainchain_getbalance)


func rpc_mainchain_sendtoaddress(amount : float, address : String) -> void:
	make_rpc_request(MAINCHAIN_RPC_PORT, "sendtoaddress", [address, amount], http_rpc_mainchain_sendtoaddress)


func rpc_testchain_getnewaddress() -> void:
	make_rpc_request(TESTCHAIN_RPC_PORT, "getnewaddress", ["", "legacy"], http_rpc_testchain_getnewaddress)


func rpc_testchain_gettransaction(txid : String) -> void:
	make_rpc_request(TESTCHAIN_RPC_PORT, "gettransaction", [txid], http_rpc_testchain_gettransaction)


func rpc_bitassets_getnewaddress() -> void:
	make_rpc_request(BITASSETS_RPC_PORT, "get_new_address", [""], http_rpc_bitassets_getnewaddress)


func rpc_bitassets_gettransaction(txid : String) -> void:
	make_rpc_request(BITASSETS_RPC_PORT, "gettransaction", [txid], http_rpc_bitassets_gettransaction)


func rpc_thunder_getnewaddress() -> void:
	make_rpc_request(THUNDER_RPC_PORT, "getnewaddress", [""], http_rpc_thunder_getnewaddress)


func rpc_thunder_gettransaction(txid : String) -> void:
	make_rpc_request(THUNDER_RPC_PORT, "gettransaction", [txid], http_rpc_thunder_gettransaction)


func make_rpc_request(port : int, method: String, params: Variant, http_request: HTTPRequest) -> void:
	var auth = rpc_user + ":" + rpc_pass
	var auth_bytes = auth.to_utf8_buffer()
	var auth_encoded = Marshalls.raw_to_base64(auth_bytes)
	var headers: PackedStringArray = []
	headers.push_back("Authorization: Basic " + auth_encoded)
	headers.push_back("content-type: application/json")
	
	var jsonrpc := JSONRPC.new()
	var req = jsonrpc.make_request(method, params, 1)
	
	http_request.request("http://127.0.0.1:" + str(port), headers, HTTPClient.METHOD_POST, JSON.stringify(req))


func get_result(response_code, body) -> Dictionary:
	var res = {}
	var json = JSON.new()
	if response_code != 200:
		if body != null:
			var err = json.parse(body.get_string_from_utf8())
			if err == OK:
				print(json.get_data())
	else:
		var err = json.parse(body.get_string_from_utf8())
		if err == OK:
			res = json.get_data() as Dictionary
	
	return res


# Mainchain RPC request results


func _on_http_request_get_balance_mainchain_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		mainchain_balance = res.result
	else:
		print("result error")
		mainchain_balance = 0
		
	mainchain_balance_updated.emit()
	
	
func _on_http_request_send_to_address_mainchain_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		mainchain_payout_txid = res.result
	else:
		print("result error")
		mainchain_payout_txid = ""
		
	mainchain_sendtoaddress_txid_result.emit()


# Testchain RPC request results


func _on_http_request_get_testchain_address_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		testchain_address = res.result
	else:
		print("result error")
		testchain_address = ""
		
	generated_testchain_address.emit()


func _on_http_request_get_testchain_transaction_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		testchain_payment_transaction = res.result
	else:
		print("result error")
		testchain_payment_transaction.clear()
		
	received_testchain_transaction_result.emit()


# BitAssets RPC results


func _on_http_request_get_bit_assets_address_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("bitasset address Result: ", res.result)
		bitassets_address = res.result
	else:
		print("bitasset address result error")
		bitassets_address = ""
		
	generated_bitassets_address.emit()


func _on_http_request_bit_assets_transaction_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		bitassets_payment_transaction = res.result
	else:
		print("result error")
		bitassets_payment_transaction.clear()
		
	received_bitassets_transaction_result.emit()


# Thunder RPC request results


func _on_http_request_get_thunder_address_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		thunder_address = res.result
	else:
		print("result error")
		thunder_address = ""
		
	generated_thunder_address.emit()


func _on_http_request_get_thunder_transaction_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var res = get_result(response_code, body)
	if res.has("result"):
		print("Result: ", res.result)
		thunder_payment_transaction = res.result
	else:
		print("result error")
		thunder_payment_transaction.clear()
		
	received_thunder_transaction_result.emit()
