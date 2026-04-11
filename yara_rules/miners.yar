rule CryptoMiner_Stratum {
    meta:
        description = "Cryptocurrency mining stratum protocol"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "stratum+tcp://" nocase
        $s2 = "stratum+ssl://" nocase
        $s3 = "stratum2+tcp://" nocase
    condition:
        any of them
}

rule CryptoMiner_Pool {
    meta:
        description = "Known mining pool domains"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $p1 = "pool.minexmr.com" nocase
        $p2 = "xmrpool.eu" nocase
        $p3 = "moneropool.com" nocase
        $p4 = "supportxmr.com" nocase
        $p5 = "nanopool.org" nocase
        $p6 = "hashvault.pro" nocase
        $p7 = "herominers.com" nocase
        $p8 = "unmineable.com" nocase
        $p9 = "2miners.com" nocase
    condition:
        any of them
}

rule CryptoMiner_Config {
    meta:
        description = "Cryptocurrency miner configuration patterns"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $c1 = "\"algo\":" nocase
        $c2 = "\"coin\":" nocase
        $c3 = "\"donate-level\"" nocase
        $c4 = "\"randomx\"" nocase
        $c5 = "\"cryptonight\"" nocase
        $c6 = "\"kawpow\"" nocase
        $c7 = "\"ethash\"" nocase
    condition:
        2 of them
}

rule XMRig_Binary {
    meta:
        description = "XMRig miner binary signatures"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "xmrig" nocase
        $s2 = "randomx_vm" nocase
        $s3 = "--donate-level"
        $s4 = "mining.subscribe" nocase
        $s5 = "mining.authorize" nocase
    condition:
        2 of them
}
