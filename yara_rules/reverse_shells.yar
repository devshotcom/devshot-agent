rule Reverse_Shell_Bash {
    meta:
        description = "Bash reverse shell indicators"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "/dev/tcp/"
        $s2 = "/dev/udp/"
        $s3 = "bash -i >& /dev/"
        $s4 = "bash -c 'bash -i >& /dev/"
    condition:
        any of them
}

rule Reverse_Shell_Netcat {
    meta:
        description = "Netcat reverse shell"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "nc -e /bin/"
        $s2 = "ncat -e /bin/"
        $s3 = "nc.traditional -e"
        $s4 = "nc -c /bin/"
    condition:
        any of them
}

rule Reverse_Shell_Pipe {
    meta:
        description = "Named pipe reverse shell (mkfifo/mknod)"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "mkfifo /tmp/"
        $s2 = "mknod /tmp/"
    condition:
        any of ($s*) and filesize < 4KB
}

rule Reverse_Shell_Socat {
    meta:
        description = "Socat reverse shell"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "socat exec:"
        $s2 = "socat TCP:"
    condition:
        all of them
}

rule Reverse_Shell_Python {
    meta:
        description = "Python reverse shell"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "import socket" nocase
        $s2 = "subprocess" nocase
        $s3 = "connect((" nocase
    condition:
        all of them and filesize < 10KB
}

rule Reverse_Shell_Perl {
    meta:
        description = "Perl reverse shell"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "use Socket" nocase
        $s2 = "socket(S,PF_INET" nocase
    condition:
        all of them and filesize < 10KB
}
