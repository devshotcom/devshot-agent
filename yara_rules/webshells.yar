rule PHP_Webshell_Eval {
    meta:
        description = "PHP webshell using eval with encoding"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "eval(base64_decode(" nocase
        $s2 = "eval(gzinflate(" nocase
        $s3 = "eval(gzuncompress(" nocase
        $s4 = "eval(str_rot13(" nocase
        $s5 = "assert(base64_decode(" nocase
    condition:
        any of them
}

rule PHP_Webshell_System {
    meta:
        description = "PHP webshell with command execution"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "system($_GET[" nocase
        $s2 = "system($_POST[" nocase
        $s3 = "system($_REQUEST[" nocase
        $s4 = "passthru($_GET[" nocase
        $s5 = "passthru($_POST[" nocase
        $s6 = "passthru($_REQUEST[" nocase
        $s7 = "shell_exec($_GET[" nocase
        $s8 = "shell_exec($_POST[" nocase
        $s9 = "exec($_GET[" nocase
        $s10 = "exec($_POST[" nocase
        $s11 = "popen($_GET[" nocase
        $s12 = "proc_open($_" nocase
    condition:
        any of them
}

rule Python_Webshell {
    meta:
        description = "Python webshell patterns"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "os.system(request" nocase
        $s2 = "subprocess.Popen(request" nocase
        $s3 = "subprocess.call(request" nocase
        $s4 = "__import__('os').popen" nocase
        // Removed bare "exec(compile(" — it matches Python stdlib pdb.py
        // and doctest.py (legitimate users of compile()+exec for the
        // debugger / doctest runner) and was auto-isolating every pool VM
        // that shipped any Python at all. The four request-bound
        // signatures above cover the actual webshell pattern; any
        // future replacement needs to require the compiled string to
        // come from request data, otherwise we just ship a new false
        // positive in its place.
    condition:
        any of them
}

rule JSP_Webshell {
    meta:
        description = "JSP webshell patterns"
        author = "DevShot Security"
        severity = "critical"
    strings:
        $s1 = "Runtime.getRuntime().exec(request" nocase
        $s2 = "ProcessBuilder(request" nocase
    condition:
        any of them
}
