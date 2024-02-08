#!/bin/bash
export COMPOSE_PROJECT_NAME=regtest

bitcoin-cli-sim() {
  docker exec regtest-bitcoind-1 bitcoin-cli -rpcuser=regtest -rpcpassword=regtest -regtest "$@"
}

elements-cli-sim() {
  docker exec regtest-elementsd-1 elements-cli "$@"
}

bitcoin-address() {
  curl localhost:3002/address/"$1" | jq .
}

liquid-address() {
  curl localhost:3003/address/"$1" | jq .
}

bitcoin-tx() {
  curl localhost:3002/tx/"$1" | jq .
}

liquid-tx() {
  curl localhost:3003/tx/"$1" | jq .
}

# args(i, cmd)
lightning-cli-sim() {
  i=$1
  shift # shift first argument so we can use $@
  docker exec regtest-clightning-$i-1 lightning-cli --network regtest "$@"
}

# args(i, cmd)
lncli-sim() {
  i=$1
  shift # shift first argument so we can use $@
  docker exec regtest-lnd-$i-1 lncli --network regtest --rpcserver=lnd-$i:10009 "$@"
}

# args(i)
fund_clightning_node() {
  address=$(lightning-cli-sim $1 newaddr | jq -r .bech32)
  echo "funding: $address on clightning-node: $1"
  bitcoin-cli-sim -named sendtoaddress address=$address amount=30 fee_rate=100 > /dev/null
}

# args(i)
fund_lnd_node() {
  address=$(lncli-sim $1 newaddress p2wkh | jq -r .address)
  echo "funding: $address on lnd-node: $1"
  bitcoin-cli-sim -named sendtoaddress address=$address amount=30 fee_rate=100 > /dev/null
}

# args(i, j)
connect_clightning_node() {
  pubkey=$(lightning-cli-sim $2 getinfo | jq -r '.id')
  lightning-cli-sim $1 connect $pubkey@regtest-clightning-$2-1:9735 | jq -r '.id'
}

regtest-start(){
  if ! command -v jq &> /dev/null
  then
      echo "jq is not installed"
      exit
  fi
  if ! command -v docker &> /dev/null
  then
      echo "docker is not installed"
      exit
  fi
  if ! command -v docker version &> /dev/null
  then
      echo "dockerd is not running"
      exit
  fi
  regtest-stop
  docker compose up -d --remove-orphans
  sudo chown -R $USER ./data
  regtest-init
  deploy-contracts
}

regtest-start-log(){
  regtest-stop
  docker compose up --remove-orphans
  sudo chown -R $USER ./data
  regtest-init
}

regtest-stop(){
  docker compose down --volumes
  # clean up lightning node data
  sudo rm -rf ./data/clightning-1 ./data/lnd-1  ./data/lnd-2 ./data/boltz/boltz.db ./data/elements/liquidregtest ./data/bitcoin/regtest
  # recreate lightning node data folders preventing permission errors
  mkdir ./data/clightning-1 ./data/lnd-1 ./data/lnd-2
}

regtest-restart(){
  regtest-stop
  regtest-start
}

bitcoin-init(){
  echo "init_bitcoin_wallet..."
  bitcoin-cli-sim createwallet regtest || bitcoin-cli-sim loadwallet regtest
  echo "mining 150 bitcoin blocks..."
  bitcoin-cli-sim -generate 150 > /dev/null
}

elements-init(){
  elements-cli-sim createwallet regtest || elements-cli-sim loadwallet regtest true
  echo "mining 150 liquid blocks..."
  elements-cli-sim -generate 150 > /dev/null
  elements-cli-sim rescanblockchain 0 > /dev/null
}

regtest-init(){
  bitcoin-init
  elements-init
  lightning-sync
  lightning-init
}

lightning-sync(){
  wait-for-clightning-sync 1
  wait-for-lnd-sync 1
  wait-for-lnd-sync 2
}

lightning-init(){
  # create 10 UTXOs for each node
  for i in 0 1 2 3 4; do
    fund_clightning_node 1
    fund_lnd_node 1
    fund_lnd_node 2
  done

  echo "mining 3 blocks..."
  bitcoin-cli-sim -generate 3 > /dev/null

  lightning-sync

  channel_confirms=6
  channel_size=24000000 # 0.024 btc
  balance_size=12000000 # 0.12 btc
  balance_size_msat=12000000000 # 0.12 btc

  # lnd-1 -> lnd-2
  lncli-sim 1 connect $(lncli-sim 2 getinfo | jq -r '.identity_pubkey')@regtest-lnd-2-1 > /dev/null
  echo "open channel from lnd-1 to lnd-2"
  lncli-sim 1 openchannel $(lncli-sim 2 getinfo | jq -r '.identity_pubkey') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-1 -> cln-1
  lncli-sim 1 connect $(lightning-cli-sim 1 getinfo | jq -r '.id')@regtest-clightning-1-1 > /dev/null
  echo "open channel from lnd-1 to cln-1"
  lncli-sim 1 openchannel $(lightning-cli-sim 1 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 1

  # lnd-2 -> cln-1
  lncli-sim 2 connect $(lightning-cli-sim 1 getinfo | jq -r '.id')@regtest-clightning-1-1 > /dev/null
  echo "open channel from lnd-2 to cln-1"
  lncli-sim 2 openchannel $(lightning-cli-sim 1 getinfo | jq -r '.id') $channel_size $balance_size > /dev/null
  bitcoin-cli-sim -generate $channel_confirms > /dev/null
  wait-for-lnd-channel 2
  wait-for-clightning-channel 1

  lightning-sync

}

wait-for-lnd-channel(){
  while true; do
    pending=$(lncli-sim $1 pendingchannels | jq -r '.pending_open_channels | length')
    echo "lnd-$1 pendingchannels: $pending"
    if [[ "$pending" == "0" ]]; then
      break
    fi
    sleep 1
  done
}

wait-for-lnd-sync(){
  while true; do
    if [[ "$(lncli-sim $1 getinfo 2>&1 | jq -r '.synced_to_chain' 2> /dev/null)" == "true" ]]; then
      echo "lnd-$1 is synced!"
      break
    fi
    echo "waiting for lnd-$1 to sync..."
    sleep 1
  done
}

wait-for-clightning-channel(){
  while true; do
    pending=$(lightning-cli-sim $1 getinfo | jq -r '.num_pending_channels | length')
    echo "cln-$1 pendingchannels: $pending"
    if [[ "$pending" == "0" ]]; then
      if [[ "$(lightning-cli-sim $1 getinfo 2>&1 | jq -r '.warning_bitcoind_sync' 2> /dev/null)" == "null" ]]; then
        if [[ "$(lightning-cli-sim $1 getinfo 2>&1 | jq -r '.warning_lightningd_sync' 2> /dev/null)" == "null" ]]; then
          break
        fi
      fi
    fi
    sleep 1
  done
}

wait-for-clightning-sync(){
  while true; do
    if [[ "$(lightning-cli-sim $1 getinfo 2>&1 | jq -r '.warning_bitcoind_sync' 2> /dev/null)" == "null" ]]; then
      if [[ "$(lightning-cli-sim $1 getinfo 2>&1 | jq -r '.warning_lightningd_sync' 2> /dev/null)" == "null" ]]; then
        echo "cln-$1 is synced!"
        break
      fi
    fi
    echo "waiting for cln-$1 to sync..."
    sleep 1
  done
}

deploy-contract() {
  docker compose exec anvil cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --create $1
}

deploy-contracts() {
  # EtherSwap
  deploy-contract 0x60c03461010e57602081017f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f81527f0f435efbd794bc89b372127f0e96dcc927b729642a259c9b4dcbab48b107caec60408301527f2a80e1ef1d7842f27f2e6be0972bb708b9a135c38860dbe73c27c3486c34f4de60608301524660808301523060a083015260a0825260c082019180831060018060401b038411176100f857826040525190206080527f9e9b7110907661cf70aeef31f56954d657589e65e35455acf5737535f33a234160a0526109c89081610114823960805181818161013e0152610421015260a05181818160e301526102d30152f35b634e487b7160e01b600052604160045260246000fd5b600080fdfe60406080815260048036101561001457600080fd5b600090813560e01c80630899146b146104bb57806335cd4ccb146104445780633644e5151461040957806354fd4d50146103ed5780636fa4ae601461031c5780638b2f8f82146102f6578063a9ab4d5b146102bb578063c3c37fbc1461029f578063cd413efa14610281578063eb84e7f2146102505763fe237d451461009957600080fd5b3461024c5760e036600319011261024c576001600160a01b03906044359060243590803590848416808503610248576064359560843560ff811680910361024457895160208101907f00000000000000000000000000000000000000000000000000000000000000008252868c8201528760608201528460808201528960a082015260a081526101288161055c565b519020908a5190602082019261190160f01b84527f00000000000000000000000000000000000000000000000000000000000000006022840152604283015260428252608082019282841067ffffffffffffffff85111761023157838d5282519020835260a082015260a43560c082015260c43560e090910152888052602090899060809060015afa156102275787511690811515918261021d575b5050156101da57506101d79495506107dc565b80f35b606490602088519162461bcd60e51b8352820152601c60248201527f4574686572537761703a20696e76616c6964207369676e6174757265000000006044820152fd5b14905038806101c4565b88513d89823e3d90fd5b634e487b7160e01b8c526041875260248cfd5b8880fd5b8680fd5b5080fd5b5082903461027d57602036600319011261027d578160209360ff9235815280855220541690519015158152f35b8280fd5b823461029c576101d76102933661051f565b939290926105dc565b80fd5b823461029c576101d76102b1366104ec565b92909133916105dc565b82843461024c578160031936011261024c57602090517f00000000000000000000000000000000000000000000000000000000000000008152f35b82843461024c5760209061031561030c3661051f565b9392909261058e565b9051908152f35b5091608036600319011261024c576024356001600160a01b0381168082036103e9576064359283341115610381575082340334811161036e5794610369916101d7959660443592356106bf565b610834565b634e487b7160e01b855260118652602485fd5b5162461bcd60e51b8152602081870152603d60248201527f4574686572537761703a2073656e7420616d6f756e74206d757374206265206760448201527f726561746572207468616e207468652070726570617920616d6f756e740000006064820152608490fd5b8380fd5b82843461024c578160031936011261024c576020905160038152f35b82843461024c578160031936011261024c57602090517f00000000000000000000000000000000000000000000000000000000000000008152f35b503461024c57610453366104ec565b9392909243851161046a57506101d79495506107dc565b608490602088519162461bcd60e51b8352820152602560248201527f4574686572537761703a207377617020686173206e6f742074696d6564206f756044820152641d081e595d60da1b6064820152fd5b50606036600319011261024c57602435906001600160a01b038216820361027d576101d791604435913490356106bf565b608090600319011261051a5760043590602435906044356001600160a01b038116810361051a579060643590565b600080fd5b60a090600319011261051a5760043590602435906001600160a01b0390604435828116810361051a5791606435908116810361051a579060843590565b60c0810190811067ffffffffffffffff82111761057857604052565b634e487b7160e01b600052604160045260246000fd5b93919092604051936020850195865260408501526bffffffffffffffffffffffff19809260601b16606085015260601b1660748301526088820152608881526105d68161055c565b51902090565b949392909260409586519160209282848201528381528881019080821067ffffffffffffffff83111761057857908085918b528251926000935b8085106106a85760009394508101838d820152039060025afa1561069d579061069b969761066c7f5664142af3dcfc3dc3de45a43f75c746bd1d8c11170a5037fdf98bdb35775137949360005196888a8961058e565b61067581610915565b600052600083528060002060ff19815416905551908152a26001600160a01b0316610834565b565b87513d6000823e3d90fd5b81850180850151908e015292909301928692610616565b919290928315610785576106d6823383878761058e565b60008181528060205260ff6040822054166107405760409181528060205220600160ff1982541617905560405193845260018060a01b0316602084015260408301527f15b4b8206809535e547317cd5cedc86cff6e7d203551f93701786ddaf14fd9f960603393a3565b60405162461bcd60e51b815260206004820152601e60248201527f4574686572537761703a20737761702065786973747320616c726561647900006044820152606490fd5b60405162461bcd60e51b815260206004820152602960248201527f4574686572537761703a206c6f636b656420616d6f756e74206d757374206e6f60448201526874206265207a65726f60b81b6064820152608490fd5b909161069b936107ef913390858561058e565b6107f881610915565b6000526000602052604060002060ff1981541690557f3fbd469ec3a5ce074f975f76ce27e727ba21c99176917b97ae2e713695582a12600080a2335b600080808094819460018060a01b03165af1903d1561090f5767ffffffffffffffff903d8281116108fb5760405192601f8201601f19908116603f01168401908111848210176108e757604052825260203d92013e5b1561089157565b60405162461bcd60e51b815260206004820152602860248201527f5472616e7366657248656c7065723a20636f756c64206e6f74207472616e736660448201526732b91022ba3432b960c11b6064820152608490fd5b634e487b7160e01b83526041600452602483fd5b634e487b7160e01b82526041600452602482fd5b5061088a565b6000526000602052600160ff6040600020541615150361093157565b60405162461bcd60e51b815260206004820152603360248201527f4574686572537761703a207377617020686173206e6f204574686572206c6f636044820152721ad959081a5b881d1a194818dbdb9d1c9858dd606a1b6064820152608490fdfea2646970667358221220b4a34a36a555807b095119eccd52363d089837b0cb7259fd3f4c8eb43225fd9864736f6c63430008180033

  # ERC20Swap
  deploy-contract 0x60c03461010e57602081017f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f81527f53904d715aff4cbf81a576b4cc3901f2c5f3e7c245cad96f11bec6c197b05ea260408301527f2a80e1ef1d7842f27f2e6be0972bb708b9a135c38860dbe73c27c3486c34f4de60608301524660808301523060a083015260a0825260c082019180831060018060401b038411176100f857826040525190206080527f170d759fe7da17205d54afcd1ce01fa24c1e02f75ffb117e59c0b25a855a944f60a052610b589081610114823960805181818161017501526104b2015260a05181818160f7015261039e0152f35b634e487b7160e01b600052604160045260246000fd5b600080fdfe608060409080825260048036101561001657600080fd5b600091823560e01c9081633644e5151461049b57508063365047211461042157806354fd4d50146104055780637beb9d6d146103dc57806391644b2b146103c1578063a9ab4d5b14610386578063b8080ab8146102d9578063bc586b28146102bb578063cd413efa1461029b578063eb84e7f21461026e5763fb35dd961461009d57600080fd5b3461026a5761010090816003193601126102665780356024356100be6104d5565b606435939092906001600160a01b0380861690818703610262576084359760a4359060ff821680920361025e578b8051918760208401927f00000000000000000000000000000000000000000000000000000000000000008452840152886060840152848a1660808401528560a08401528b60c084015260c0835260e083019183831067ffffffffffffffff84111761024b57938d938f9293608094610122602098838752845190209184019361190160f01b85527f00000000000000000000000000000000000000000000000000000000000000006101028201520152604281526101a981610576565b51902091519182528482015260c4358e82015260e435606082015282805260015afa1561024157885116908115159182610237575b5050156101f457506101f1959650610904565b80f35b606490602089519162461bcd60e51b8352820152601c60248201527f4552433230537761703a20696e76616c6964207369676e6174757265000000006044820152fd5b14905038806101de565b89513d8a823e3d90fd5b634e487b7160e01b8e526041885260248efd5b8a80fd5b8880fd5b8280fd5b5080fd5b50829034610266576020366003190112610266578160209360ff9235815280855220541690519015158152f35b82346102b8576101f16102ad366104f0565b939190923392610828565b80fd5b82346102b8576101f16102cd3661052d565b94939093929192610828565b508260a036600319011261026657826102f06104d5565b6064356001600160a01b0381169081900361026657828161031c82948394608435916024358b35610614565b34905af1610328610962565b5015610332578280f35b906020608492519162461bcd60e51b8352820152602860248201527f5472616e7366657248656c7065723a20636f756c64206e6f74207472616e736660448201526732b91022ba3432b960c11b6064820152fd5b82843461026a578160031936011261026a57602090517f00000000000000000000000000000000000000000000000000000000000000008152f35b82346102b8576101f16103d3366104f0565b93929092610614565b82843461026a576020906103fe6103f23661052d565b949390939291926105a8565b9051908152f35b82843461026a578160031936011261026a576020905160038152f35b503461026a57610430366104f0565b9493909392919243861161044a57506101f1959650610904565b608490602089519162461bcd60e51b8352820152602560248201527f4552433230537761703a207377617020686173206e6f742074696d6564206f756044820152641d081e595d60da1b6064820152fd5b83903461026a578160031936011261026a576020907f00000000000000000000000000000000000000000000000000000000000000008152f35b604435906001600160a01b03821682036104eb57565b600080fd5b60a09060031901126104eb5760043590602435906001600160a01b039060443582811681036104eb579160643590811681036104eb579060843590565b60c09060031901126104eb5760043590602435906001600160a01b0360443581811681036104eb579160643582811681036104eb579160843590811681036104eb579060a43590565b6080810190811067ffffffffffffffff82111761059257604052565b634e487b7160e01b600052604160045260246000fd5b949291939093604051946020860196875260408601526bffffffffffffffffffffffff199283809260601b16606087015260601b16607485015260601b166088830152609c820152609c815260c0810181811067ffffffffffffffff8211176105925760405251902090565b9290939184156107d1576040918251602090818101906323b872dd60e01b82523360248201523060448201528860648201526064815260a0810181811067ffffffffffffffff821117610592578652600080928192519082885af1610677610962565b816107a1575b501561074157610691863385878c8c6105a8565b80825281835260ff86832054166106fd578152808252849020805460ff1916600117905583519687526001600160a01b03928316908701521690840152606083015233917fa98eaa2bd8230d87a1a4c356f5c1d41cb85ff88131122ec8b1931cb9d31ae14590608090a3565b855162461bcd60e51b815260048101849052601e60248201527f4552433230537761703a20737761702065786973747320616c726561647900006044820152606490fd5b845162461bcd60e51b815260048101839052603360248201527f5472616e7366657248656c7065723a20636f756c64206e6f74207472616e7366604482015272657246726f6d20455243323020746f6b656e7360681b6064820152608490fd5b805180159250849083156107b9575b5050503861067d565b6107c993508201810191016109ad565b3883816107b0565b60405162461bcd60e51b815260206004820152602960248201527f4552433230537761703a206c6f636b656420616d6f756e74206d757374206e6f60448201526874206265207a65726f60b81b6064820152608490fd5b959493909360409687519160209282848201528381528981019080821067ffffffffffffffff83111761059257908491818c528b815160005b8181106108ed575090600083928195940191820152039060025afa156108e257906108e097986108ba7f5664142af3dcfc3dc3de45a43f75c746bd1d8c11170a5037fdf98bdb3577513794936000519689898c8a6105a8565b6108c3816109c5565b600052600083528060002060ff19815416905551908152a2610a43565b565b88513d6000823e3d90fd5b8381018087015193019290925287948e9201610861565b90926108e0946109189133908587866105a8565b610921816109c5565b6000526000602052604060002060ff1981541690557f3fbd469ec3a5ce074f975f76ce27e727ba21c99176917b97ae2e713695582a12600080a23390610a43565b3d156109a85767ffffffffffffffff903d8281116105925760405192601f8201601f19908116603f01168401908111848210176105925760405282523d6000602084013e565b606090565b908160209103126104eb575180151581036104eb5790565b6000526000602052600160ff604060002054161515036109e157565b60405162461bcd60e51b815260206004820152603460248201527f4552433230537761703a207377617020686173206e6f20746f6b656e73206c6f60448201527318dad959081a5b881d1a194818dbdb9d1c9858dd60621b6064820152608490fd5b6000929183809360405190602082019363a9059cbb60e01b855260018060a01b03166024830152604482015260448152610a7c81610576565b51925af1610a88610962565b81610af3575b5015610a9657565b60405162461bcd60e51b815260206004820152602f60248201527f5472616e7366657248656c7065723a20636f756c64206e6f74207472616e736660448201526e657220455243323020746f6b656e7360881b6064820152608490fd5b8051801592508215610b08575b505038610a8e565b610b1b92506020809183010191016109ad565b3880610b0056fea26469706673582212204dae89131edfecec676f755ee25c8510240e47b05e5dc993d98cfbe1c523891c64736f6c63430008180033
}
