output "sharded_topology" {
  description = "Sharded cluster topology snapshot."
  value = {
    config_servers = [for h, s in local.config_nodes : "${h}:${s.port}"]
    shard_1        = [for h, s in local.shard_1_nodes : "${h}:${s.port}"]
    shard_2        = [for h, s in local.shard_2_nodes : "${h}:${s.port}"]
    mongos         = [for h, s in local.mongos_nodes : "${h}:${s.port}"]
    config_db_uri  = local.config_db_uri
    next_step      = "Connect via: mongosh 'mongodb://192.168.70.58:27017,192.168.70.59:27017/?authSource=admin'"
  }
}
