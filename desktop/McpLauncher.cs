using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

// Stable v1 bootstrap protocol. Upgrades preserve a running executable;
// each new process reads the current installation instead of a version path.
internal static class McpLauncher {
    const string Identity = "PhoneBridge MCP bootstrap v1";
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo { public int cb; public string reserved, desktop, title; public int x,y,xSize,ySize,xCount,yCount,fill,flags; public short show,reserved2; public IntPtr reservedPtr,stdin,stdout,stderr; }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation { public IntPtr process,thread; public int pid,tid; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr processAttrs, IntPtr threadAttrs, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation process);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static string Text(Dictionary<string,object> config, string key) { object value; if (!config.TryGetValue(key,out value) || !(value is string)) throw new Exception("Invalid desktop configuration."); return (string)value; }
    static string PathValue(string path) { if (!Path.IsPathRooted(path) || path.IndexOfAny(new[]{'"','\r','\n','\0'})>=0 || Path.GetFullPath(path)!=path) throw new Exception("Invalid desktop path."); return path; }
    static bool OwnerMatches(string owner, string user, string tokenOwner) { return owner==user || owner==tokenOwner; }
    static void OwnedFile(string path, string sid) {
        var file = new FileInfo(path);
        // Elevated Windows tokens can create files owned by their default owner
        // group. Match that exact token owner as well as the user; never accept
        // arbitrary group membership. The JSON ownerSid must still match User.
        if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint)!=0 || file.Length>32768 || !OwnerMatches(File.GetAccessControl(path).GetOwner(typeof(SecurityIdentifier)).Value,sid,WindowsIdentity.GetCurrent().Owner.Value)) throw new Exception("Missing, invalid or foreign desktop configuration.");
    }
    static bool PrivateAddress(string value) {
        string[] pieces=value.Split('.'); if(pieces.Length!=4)return false;
        int[] octets=new int[4];
        for(int i=0;i<4;i++)if(!int.TryParse(pieces[i],out octets[i]) || octets[i]<0 || octets[i]>255 || octets[i].ToString()!=pieces[i])return false;
        return octets[0]==10 || (octets[0]==172 && octets[1]>=16 && octets[1]<=31) || (octets[0]==192 && octets[1]==168);
    }
    static void Usage(TextWriter output) {
        output.WriteLine("Usage: PhoneBridgeMcp.exe [--help | --version | --launcher-version]");
        output.WriteLine("No arguments: start the installed PhoneBridge MCP server over stdio.");
        output.WriteLine("--version: show the current installed App version and stable launcher identity.");
        output.WriteLine("--launcher-version: show the bootstrap protocol identity used by the installer.");
    }
    static bool VersionValue(string value) { return Regex.IsMatch(value,@"^\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?(?:\+[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$"); }
    static string AppVersion(string root) {
        string manifest=Path.Combine(root,"package-manifest.json");
        if(File.Exists(manifest)) {
            var metadata=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(manifest));
            string value=Text(metadata,"version");
            if(Text(metadata,"product")!="PhoneBridge" || !VersionValue(value))throw new Exception("Invalid installed App version.");
            return value;
        }
        string pubspec=Path.Combine(root,"mobile","pubspec.yaml");
        if(File.Exists(pubspec)) {
            var match=Regex.Match(File.ReadAllText(pubspec),@"^version:\s*([^\s#]+)",RegexOptions.Multiline);
            if(match.Success && VersionValue(match.Groups[1].Value))return match.Groups[1].Value.Split('+')[0];
        }
        var package=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(root,"bridge","package.json")));
        string version=Text(package,"version");if(!VersionValue(version))throw new Exception("Invalid MCP package version.");return version;
    }
    static int Main(string[] args) {
        string stage="arguments";
        try {
            if(args.Length==1 && args[0]=="--launcher-version") { Console.WriteLine(Identity); return 0; }
            if(args.Length==1 && (args[0]=="--help" || args[0]=="-h")) { Usage(Console.Out); return 0; }
            bool showVersion=args.Length==1 && args[0]=="--version";
            if(args.Length!=0 && !showVersion) { Console.Error.WriteLine("Unknown PhoneBridge MCP arguments.");Usage(Console.Error);return 2; }
            string state=Directory.GetParent(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)).FullName;
            string configPath=Path.Combine(state,"desktop.json"),sid=WindowsIdentity.GetCurrent().User.Value;
            stage="configuration-file"; OwnedFile(configPath,sid);
            stage="configuration-json";
            var config=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(configPath));
            stage="configuration-user";
            if(Text(config,"schema")!="phonebridge-desktop-v1" || Text(config,"ownerSid")!=sid)throw new Exception("Unsupported desktop configuration or another owner.");
            stage="configuration-paths";
            string root=PathValue(Text(config,"projectRoot")),node=PathValue(Text(config,"nodePath")),host=Text(config,"hostAddress");
            if(showVersion) { stage="app-version";Console.WriteLine("PhoneBridge App "+AppVersion(root));Console.WriteLine("MCP launcher: "+Identity);return 0; }
            stage="configuration-endpoint";
            object rawPort; if(!config.TryGetValue("port",out rawPort) || !(rawPort is int) || (int)rawPort<1 || (int)rawPort>65535 || !PrivateAddress(host))throw new Exception("Invalid desktop endpoint.");
            string entry=Path.Combine(root,"bridge","dist","mcp.js");
            stage="runtime-files";
            if(!File.Exists(node) || !File.Exists(entry))throw new Exception("The installed MCP runtime is missing. Reinstall PhoneBridge.");
            stage="credential-path"; string credential=config.ContainsKey("credentialFile")?PathValue(Text(config,"credentialFile")):Path.Combine(state,"pairing.json");
            stage="environment";
            var environment=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach(DictionaryEntry item in Environment.GetEnvironmentVariables()) environment[(string)item.Key]=(string)item.Value;
            environment.Remove("PHONEBRIDGE_TOKEN"); environment.Remove("NODE_OPTIONS"); environment.Remove("NODE_PATH");
            environment["PHONEBRIDGE_URL"]="http://"+host+":"+(int)rawPort;
            environment["PHONEBRIDGE_CREDENTIAL_FILE"]=credential;
            environment["PHONEBRIDGE_DESKTOP_CONFIG"]=configPath;
            environment["PATH"]=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0")+";"+Environment.GetEnvironmentVariable("PATH");
            var block=new StringBuilder();foreach(var item in environment)block.Append(item.Key).Append('=').Append(item.Value).Append('\0');block.Append('\0');
            IntPtr env=Marshal.StringToHGlobalUni(block.ToString());
            var startup=new StartupInfo {cb=Marshal.SizeOf(typeof(StartupInfo)),flags=0x100,stdin=GetStdHandle(-10),stdout=GetStdHandle(-11),stderr=GetStdHandle(-12)};
            ProcessInformation child;
            stage="runtime-start";
            try { if(!CreateProcess(node,new StringBuilder("\""+node+"\" \""+entry+"\""),IntPtr.Zero,IntPtr.Zero,true,0x08000400,env,root,ref startup,out child))throw new Exception("Cannot start the installed MCP runtime."); }
            finally { Marshal.FreeHGlobal(env); }
            try { WaitForSingleObject(child.process,0xffffffff); uint code;if(!GetExitCodeProcess(child.process,out code))return 1;return unchecked((int)code); }
            finally {CloseHandle(child.thread);CloseHandle(child.process);}
        } catch(Exception) { Console.Error.WriteLine("PhoneBridge MCP could not start. Check the current-user desktop installation and configuration. Stage: "+stage+".");return 1; }
    }
}
