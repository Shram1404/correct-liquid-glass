// Demo: live liquid-glass refraction over the desktop via Windows.Graphics.Capture.
// Usage: LiquidGlassDemo.exe [seconds=60] [fpsCap=30] [rowHeightPx=48]
using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using Vortice.D3DCompiler;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

int seconds = args.Length > 0 ? int.Parse(args[0]) : 60;
int fpsCap = args.Length > 1 ? int.Parse(args[1]) : 30;

Native.SetProcessDpiAwarenessContext(-4);
float s = Native.GetDpiForSystem() / 96f;
var hmon = Native.MonitorFromPoint(default, 1);
var mi = new Native.MONITORINFO { cbSize = Marshal.SizeOf<Native.MONITORINFO>() };
Native.GetMonitorInfoW(hmon, ref mi);
int monX = mi.rcMonitor.left, monY = mi.rcMonitor.top, W = mi.rcMonitor.right - mi.rcMonitor.left, monH = mi.rcMonitor.bottom - mi.rcMonitor.top;
float barH = args.Length > 2 ? float.Parse(args[2]) : 48f;
// two rows: base size on top, double size below
float py = barH * 0.125f * s, ph = barH * 0.75f * s, gapY = 24 * s, gap = 24 * s;
int H = (int)(py + ph + gapY + 2 * ph + py), M = (int)(barH * s);

int offY = (monH - H) / 2; // strip sits in the vertical middle of the screen
// --- window ---
Native.WndProc proc = (h, m, w, l) => Native.DefWindowProcW(h, m, w, l);
var wc = new Native.WNDCLASSEXW { cbSize = Marshal.SizeOf<Native.WNDCLASSEXW>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc), lpszClassName = "LiquidGlassDemo" };
Native.RegisterClassExW(ref wc);
var hwnd = Native.CreateWindowExW(0x8 | 0x80 | 0x08000000, "LiquidGlassDemo", "LiquidGlassDemo", unchecked((int)0x80000000), monX, monY + offY, W, H, 0, 0, 0, 0);
Native.SetWindowDisplayAffinity(hwnd, 0x11); // WDA_EXCLUDEFROMCAPTURE
Native.ShowWindow(hwnd, 4);

// --- d3d ---
D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport, [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0], out ID3D11Device? device, out ID3D11DeviceContext? ctx).CheckError();
using (var mt = device!.QueryInterface<ID3D11Multithread>()) mt.SetMultithreadProtected(true);
var dxgiDevice = device.QueryInterface<IDXGIDevice>();
dxgiDevice.GetAdapter(out IDXGIAdapter adapter).CheckError();
var factory = adapter.GetParent<IDXGIFactory2>();
var swap = factory.CreateSwapChainForHwnd(device, hwnd, new SwapChainDescription1
{
    Width = (uint)W, Height = (uint)H, Format = Format.B8G8R8A8_UNorm, BufferCount = 2,
    BufferUsage = Usage.RenderTargetOutput, SampleDescription = new(1, 0),
    SwapEffect = SwapEffect.FlipDiscard, Scaling = Scaling.Stretch, AlphaMode = Vortice.DXGI.AlphaMode.Ignore,
});
var stripTex = device.CreateTexture2D(new Texture2DDescription(Format.B8G8R8A8_UNorm, (uint)W, (uint)(H + M), 1, 1, BindFlags.ShaderResource));
var srv = device.CreateShaderResourceView(stripTex);
var sampler = device.CreateSamplerState(SamplerDescription.LinearClamp);
string hlsl = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "liquid-glass.hlsl"));
var vs = device.CreateVertexShader(Compiler.Compile(hlsl, "VS", "liquid-glass.hlsl", "vs_5_0").Span);
var ps = device.CreatePixelShader(Compiler.Compile(hlsl, "PS", "liquid-glass.hlsl", "ps_5_0").Span);
bool first = true, snapped = false;
// hot reload: edit liquid-glass.hlsl next to the exe and the strip picks it up
var hlslPath = Path.Combine(AppContext.BaseDirectory, "liquid-glass.hlsl");
var watcher = new FileSystemWatcher(AppContext.BaseDirectory, "liquid-glass.hlsl") { NotifyFilter = NotifyFilters.LastWrite, EnableRaisingEvents = true };
watcher.Changed += (_, _) =>
{
    try
    {
        Thread.Sleep(100);
        var code = Compiler.Compile(File.ReadAllText(hlslPath), "PS", "liquid-glass.hlsl", "ps_5_0");
        lock (ctx!) { var old = ps; ps = device.CreatePixelShader(code.Span); old.Dispose(); first = true; }
        Console.WriteLine("shader reloaded");
    }
    catch (Exception e) { Console.WriteLine($"shader error: {e.Message}"); }
};
var cb = device.CreateBuffer(new BufferDescription((uint)Marshal.SizeOf<Cb>(), BindFlags.ConstantBuffer));
var shapes = new List<(Vector4 Rect, Vector4 R)>();
void Row(float y, float k) // circle, long stadium, rounded rectangle; row centred horizontally
{
    float h = ph * k, wB = 380 * s * k, wC = 320 * s * k, x = (W - (h + gap + wB + gap + wC)) / 2;
    shapes.Add((new(x, y, h, h), new(h / 2, h / 2, 0, 0)));
    shapes.Add((new(x + h + gap, y, wB, h), new(h / 2, h / 2, 0, 0)));
    shapes.Add((new(x + h + gap + wB + gap, y, wC, h), new(h * 0.22f, h / 2, 0, 0)));
}
Row(py, 1);
Row(py + ph + gapY, 2);
var cbData = new Cb
{
    WinSize = new(W, H), TexSize = new(W, H + M),
    S0 = shapes[0].Rect, S1 = shapes[1].Rect, S2 = shapes[2].Rect, S3 = shapes[3].Rect, S4 = shapes[4].Rect, S5 = shapes[5].Rect,
    R0 = shapes[0].R, R1 = shapes[1].R, R2 = shapes[2].R, R3 = shapes[3].R, R4 = shapes[4].R, R5 = shapes[5].R,
    Flags = new(Environment.GetEnvironmentVariable("GLASS_TEST") is "1" or "2" ? 1 : 0, Environment.GetEnvironmentVariable("GLASS_TEST") == "2" ? 1 : 0, 0, 0),
};
ctx!.UpdateSubresource(in cbData, cb);
// click-through outside the glass: the window only exists inside the pills (+1px for the AA edge)
nint rgn = Native.CreateRectRgn(0, 0, 0, 0);
foreach (var (pr, rr) in shapes)
{
    int d2 = (int)(rr.X * 2) + 2;
    nint one = Native.CreateRoundRectRgn((int)pr.X - 1, (int)pr.Y - 1, (int)(pr.X + pr.Z) + 2, (int)(pr.Y + pr.W) + 2, d2, d2);
    Native.CombineRgn(rgn, rgn, one, 2); // RGN_OR
    Native.DeleteObject(one);
}
Native.SetWindowRgn(hwnd, rgn, true);

// GPU timing ring
const int Ring = 8;
var qDisjoint = new ID3D11Query[Ring]; var qStart = new ID3D11Query[Ring]; var qEnd = new ID3D11Query[Ring]; var qPending = new bool[Ring];
for (int i = 0; i < Ring; i++)
{
    qDisjoint[i] = device.CreateQuery(new QueryDescription(QueryType.TimestampDisjoint));
    qStart[i] = device.CreateQuery(new QueryDescription(QueryType.Timestamp));
    qEnd[i] = device.CreateQuery(new QueryDescription(QueryType.Timestamp));
}
int qi = 0; double gpuMsSum = 0; int gpuSamples = 0;
long processed = 0, skipped = 0, totalProcessed = 0, totalSkipped = 0;

// --- capture ---
Native.CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.NativePointer, out IntPtr insp).CheckError();
var winrtDevice = MarshalInterface<IDirect3DDevice>.FromAbi(insp);
var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
var itemIid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
var item = GraphicsCaptureItem.FromAbi(interop.CreateForMonitor(hmon, in itemIid));
try { await GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless); } catch (Exception e) { Console.WriteLine($"borderless access: {e.Message}"); }
var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(winrtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, item.Size);
var session = pool.CreateCaptureSession(item);
session.IsCursorCaptureEnabled = false;
try { session.IsBorderRequired = false; } catch (Exception e) { Console.WriteLine($"IsBorderRequired: {e.Message}"); }
session.MinUpdateInterval = TimeSpan.FromSeconds(1.0 / fpsCap);
session.DirtyRegionMode = GraphicsCaptureDirtyRegionMode.ReportOnly;
var stripRect = new RectInt32(0, offY, W, H + M);
var texIid = typeof(ID3D11Texture2D).GUID;

pool.FrameArrived += (sender, _) =>
{
    using var frame = sender.TryGetNextFrame();
    if (frame is null) return;
    bool hit = first;
    foreach (var r in frame.DirtyRegions)
    {
        if (r.X < stripRect.X + stripRect.Width && r.X + r.Width > stripRect.X && r.Y < stripRect.Y + stripRect.Height && r.Y + r.Height > stripRect.Y) { hit = true; break; }
    }
    if (!hit) { Interlocked.Increment(ref skipped); return; }
    first = false;
    using var tex = new ID3D11Texture2D(frame.Surface.As<IDirect3DDxgiInterfaceAccess>().GetInterface(in texIid));
    lock (ctx)
    {
        ReadTimings();
        int q = qi; qi = (qi + 1) % Ring;
        bool time = !qPending[q];
        if (time) { ctx.Begin(qDisjoint[q]); ctx.End(qStart[q]); }
        ctx.CopySubresourceRegion(stripTex, 0, 0, 0, 0, tex, 0, new Box(0, offY, 0, W, offY + H + M, 1));
        using var back = swap.GetBuffer<ID3D11Texture2D>(0);
        using var rtv = device.CreateRenderTargetView(back);
        ctx.OMSetRenderTargets(rtv);
        ctx.RSSetViewport(new Viewport(W, H));
        ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        ctx.VSSetShader(vs); ctx.PSSetShader(ps);
        ctx.PSSetShaderResource(0, srv); ctx.PSSetSampler(0, sampler); ctx.PSSetConstantBuffer(0, cb);
        ctx.Draw(3, 0);
        if (time) { ctx.End(qEnd[q]); ctx.End(qDisjoint[q]); qPending[q] = true; }
        if (!snapped && totalProcessed + processed > 20) { snapped = true; SaveBmp(back, Path.Combine(AppContext.BaseDirectory, "snap.bmp")); }
        swap.Present(0, PresentFlags.None);
    }
    Interlocked.Increment(ref processed);
};

void SaveBmp(ID3D11Texture2D src, string path)
{
    using var st = device.CreateTexture2D(new Texture2DDescription(Format.B8G8R8A8_UNorm, (uint)W, (uint)H, 1, 1, BindFlags.None, ResourceUsage.Staging, CpuAccessFlags.Read));
    ctx.CopyResource(st, src);
    var map = ctx.Map(st, 0, MapMode.Read);
    using var fs = new BinaryWriter(File.Create(path));
    int row = W * 4;
    fs.Write((ushort)0x4D42); fs.Write(54 + row * H); fs.Write(0); fs.Write(54);
    fs.Write(40); fs.Write(W); fs.Write(-H); fs.Write((ushort)1); fs.Write((ushort)32); fs.Write(0); fs.Write(row * H); fs.Write(0); fs.Write(0); fs.Write(0); fs.Write(0);
    var buf = new byte[row];
    for (int y = 0; y < H; y++) { Marshal.Copy(map.DataPointer + (nint)(y * map.RowPitch), buf, 0, row); fs.Write(buf); }
    ctx.Unmap(st, 0);
}

void ReadTimings()
{
    for (int i = 0; i < Ring; i++)
    {
        if (!qPending[i]) continue;
        if (ctx.GetData(qDisjoint[i], AsyncGetDataFlags.DoNotFlush, out QueryDataTimestampDisjoint dj) &&
            ctx.GetData(qStart[i], AsyncGetDataFlags.DoNotFlush, out ulong t0) &&
            ctx.GetData(qEnd[i], AsyncGetDataFlags.DoNotFlush, out ulong t1))
        {
            qPending[i] = false;
            if (!dj.Disjoint) { gpuMsSum += (t1 - t0) * 1000.0 / dj.Frequency; gpuSamples++; }
        }
    }
}

session.StartCapture();
Console.WriteLine($"monitor {W}px wide, strip {H}px, cap {fpsCap} fps, running {seconds}s");
Console.WriteLine("sec | rendered | skipped | ourGPU ms/frame | ourCPU %");

var me = Process.GetCurrentProcess();
var cpu0 = me.TotalProcessorTime; var sw = Stopwatch.StartNew();
var timer = new Timer(_ =>
{
    me.Refresh();
    var cpu = me.TotalProcessorTime; double el = sw.Elapsed.TotalSeconds;
    double cpuPct = (cpu - cpu0).TotalSeconds / el / Environment.ProcessorCount * 100 * 1; cpu0 = cpu; sw.Restart();
    double gms; lock (ctx) { gms = gpuSamples > 0 ? gpuMsSum / gpuSamples : 0; gpuMsSum = 0; gpuSamples = 0; }
    long p = Interlocked.Exchange(ref processed, 0), k = Interlocked.Exchange(ref skipped, 0);
    totalProcessed += p; totalSkipped += k;
    Console.WriteLine($"{DateTime.Now:HH:mm:ss} | {p,8} | {k,7} | {gms,15:F3} | {cpuPct,7:F2}");
}, null, 1000, 1000);

var end = DateTime.UtcNow.AddSeconds(seconds);
while (DateTime.UtcNow < end)
{
    while (Native.PeekMessageW(out var msg, 0, 0, 0, 1)) { Native.TranslateMessage(ref msg); Native.DispatchMessageW(ref msg); }
    Thread.Sleep(50);
}
session.Dispose(); pool.Dispose(); timer.Dispose();
Console.WriteLine($"TOTAL rendered={totalProcessed} skipped={totalSkipped}");

[StructLayout(LayoutKind.Sequential)]
struct Cb { public Vector2 WinSize, TexSize; public Vector4 S0, S1, S2, S3, S4, S5, R0, R1, R2, R3, R4, R5, Flags; }

[ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IGraphicsCaptureItemInterop { IntPtr CreateForWindow(IntPtr window, in Guid iid); IntPtr CreateForMonitor(IntPtr monitor, in Guid iid); }

[ComImport, Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDirect3DDxgiInterfaceAccess { IntPtr GetInterface(in Guid iid); }

static class Native
{
    public delegate nint WndProc(nint h, uint m, nint w, nint l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEXW { public int cbSize; public uint style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public nint hInstance, hIcon, hCursor, hbrBackground; public string? lpszMenuName; public string lpszClassName; public nint hIconSm; }
    public struct RECT { public int left, top, right, bottom; }
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    public struct MSG { public nint hwnd; public uint message; public nint wParam, lParam; public uint time; public int x, y; }
    [DllImport("user32")] public static extern bool SetProcessDpiAwarenessContext(nint v);
    [DllImport("user32")] public static extern uint GetDpiForSystem();
    [DllImport("user32")] public static extern nint MonitorFromPoint(System.Drawing.Point p, uint flags);
    [DllImport("user32")] public static extern bool GetMonitorInfoW(nint m, ref MONITORINFO mi);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern ushort RegisterClassExW(ref WNDCLASSEXW wc);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern nint CreateWindowExW(int ex, string cls, string name, int style, int x, int y, int w, int h, nint parent, nint menu, nint inst, nint param);
    [DllImport("user32")] public static extern nint DefWindowProcW(nint h, uint m, nint w, nint l);
    [DllImport("user32")] public static extern bool ShowWindow(nint h, int cmd);
    [DllImport("user32")] public static extern bool SetWindowDisplayAffinity(nint h, uint a);
    [DllImport("user32")] public static extern bool PeekMessageW(out MSG m, nint h, uint a, uint b, uint remove);
    [DllImport("user32")] public static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32")] public static extern nint DispatchMessageW(ref MSG m);
    [DllImport("gdi32")] public static extern nint CreateRectRgn(int a, int b, int c, int d);
    [DllImport("gdi32")] public static extern nint CreateRoundRectRgn(int a, int b, int c, int d, int w, int h);
    [DllImport("gdi32")] public static extern int CombineRgn(nint dst, nint a, nint b, int mode);
    [DllImport("gdi32")] public static extern bool DeleteObject(nint o);
    [DllImport("user32")] public static extern int SetWindowRgn(nint h, nint rgn, bool redraw);
    [DllImport("d3d11")] public static extern SharpGen.Runtime.Result CreateDirect3D11DeviceFromDXGIDevice(nint dxgiDevice, out nint graphicsDevice);
}
