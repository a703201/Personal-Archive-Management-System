// ============================================================
// AMS · external-ppocrv5 · C 桥接层（PP-OCRv5 mobile + ONNX Runtime C API）
//
// 这是「真推理 spike」验证通过的桥接层的**生产精简版**：
//   · 仅依赖 ONNX Runtime C API；图片由仓颉 MediaEngine 解码成
//     RasterImage（RGB 行主序，pixels.size = w*h*3）后通过 FFI 传入，
//     本层不再自带图片解码（stb_image 已移除）。
//   · det / rec 输出形状运行时动态读取，不硬编码。
//   · DB 后处理已升级为「阈值 + 8 连通域 + 凸包/旋转卡壳最小面积
//     外接四边形 + Unclip 边偏移求交 + 透视变换裁剪」，可覆盖倾斜文本。
//     任意凹多边形仍不予支持（未引入通用 Vatti 多边形裁剪库）；
//     AMS_OCR_DET_QUAD=0 可整条回退到旧的轴对齐框路径（零回归开关）。
//   · AMS_OCR_CHANNEL_ORDER=bgr 可切换通道序（默认 rgb）。
//     本模型是 web 导出版，实测彩色/灰度图 RGB 序正确；开关供运维在
//     其它导出版本上校准，不做隐式猜测。
//   · rec 用 CTC 贪心解码 + 字典；Class 0 = 空白，Class k+1 = dict[k]，
//     末类 = 空格（与 PP-OCRv5 约定一致）。
//
// 两个 spike 中踩过的致命坑（已修复，勿回退）：
//   1) nakamura 导出的 ONNX 把 ImageNet mean/std 归一化**烘焙进图内**
//      （含 Sigmoid），故必须喂「原始 [0,1]」输入，禁再叠加归一化。
//   2) ORT 要求 NCHW [1,3,H,W]；此前误写成 HWC 导致通道错乱。
//
// ABI（给仓颉 foreign 用，已与 ocr_ext.cj 对齐）：
//   ams_ocr_init() -> Int32            (0=OK, -1=不可用/缺模型)
//   ams_ocr_run(rgb,w,h,out_text,cap) -> Int32
//                                   (文本字节数; 0=空; <0=错误)
//   ams_ocr_free() -> Int32           (0)
//
// 模型路径由环境变量给出（避免仓颉侧构造 CString 的坑）：
//   AMS_OCR_DET / AMS_OCR_REC / AMS_OCR_DICT
// ============================================================
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static const OrtApi* g_ort = NULL;
static OrtEnv* g_env = NULL;
static OrtSession* g_det = NULL;
static OrtSession* g_rec = NULL;
static OrtSessionOptions* g_opt = NULL;

// det/rec 输入/输出名（init 时查询）
static char* g_det_in = NULL;
static char* g_det_out = NULL;
static char* g_rec_in = NULL;
static char* g_rec_out = NULL;

// 字典
static char** g_dict = NULL;
static int g_dict_len = 0;
static int g_rec_classes = 0;   // rec 输出类数（含 blank + 空格）

// 运行时可调（ams_ocr_init 读环境变量）
static int   g_channel_bgr   = 0;   // 1 = 输入按 BGR 解释
static int   g_use_quad      = 1;   // 0 = 回退旧的轴对齐框路径
static float g_unclip_ratio  = 1.6f;

// ---- 错误回传 ----
static int fail(const char* msg) {
    fprintf(stderr, "[ocr_bridge] ERROR: %s\n", msg);
    return -1;
}

// ============================================================
// 字典解析（JSON 数组，支持裸 UTF-8 与 \uXXXX 转义）
// ============================================================
static int utf8_encode(uint32_t cp, char* out) {
    if (cp <= 0x7F) { out[0] = (char)cp; return 1; }
    if (cp <= 0x7FF) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    out[0] = (char)(0xE0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (char)(0x80 | (cp & 0x3F));
    return 3;
}

static int load_dict(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { fail("dict open"); return -1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(n + 1);
    if (!buf) { fclose(f); fail("dict malloc"); return -1; }
    fread(buf, 1, n, f); buf[n] = 0; fclose(f);

    int cap = 20000;
    g_dict = (char**)malloc(sizeof(char*) * cap);
    g_dict_len = 0;

    const char* p = buf;
    while (*p && *p != '[') p++;
    if (!*p) { free(buf); fail("dict no array"); return -1; }
    p++;
    while (*p) {
        while (*p && *p != '"' && *p != ']') p++;
        if (*p == ']') break;
        if (*p != '"') break;
        p++;
        char tmp[16];
        int tl = 0;
        while (*p && *p != '"') {
            if (*p == '\\') {
                p++;
                if (*p == 'u') {
                    p++;
                    uint32_t cp = 0;
                    for (int k = 0; k < 4; k++) {
                        char c = *p++;
                        cp <<= 4;
                        if (c >= '0' && c <= '9') cp |= (c - '0');
                        else if (c >= 'a' && c <= 'f') cp |= (c - 'a' + 10);
                        else if (c >= 'A' && c <= 'F') cp |= (c - 'A' + 10);
                    }
                    tl += utf8_encode(cp, tmp + tl);
                } else {
                    if (tl < (int)sizeof(tmp) - 1) tmp[tl++] = *p++;
                }
            } else {
                if (tl < (int)sizeof(tmp) - 1) tmp[tl++] = *p++;
            }
        }
        if (*p == '"') p++;
        char* s = (char*)malloc(tl + 1);
        memcpy(s, tmp, tl); s[tl] = 0;
        if (g_dict_len < cap) g_dict[g_dict_len++] = s;
        while (*p && *p != ',' && *p != ']') p++;
        if (*p == ']') break;
        if (*p == ',') p++;
    }
    free(buf);
    fprintf(stderr, "[ocr_bridge] dict loaded: %d entries\n", g_dict_len);
    return 0;
}

// ============================================================
// ORT 工具
// ============================================================
static int read_dims(OrtSession* s, OrtValue* v, int64_t* dims, size_t* nd) {
    OrtTensorTypeAndShapeInfo* info = NULL;
    if (g_ort->GetTensorTypeAndShape(v, &info) != NULL) return -1;
    size_t cnt = 0; g_ort->GetDimensionsCount(info, &cnt);
    g_ort->GetDimensions(info, dims, cnt);
    *nd = cnt;
    g_ort->ReleaseTensorTypeAndShapeInfo(info);
    return 0;
}

// ============================================================
// 图像预处理：RGB -> float CHW, 原始 [0,1]（pixel/255）
// 见文件头「致命坑 1/2」：必须 raw[0,1] + NCHW。
// ============================================================
static float* resize_rgb(const uint8_t* src, int w, int h,
                         int tw, int th, int do_norm) {
    size_t n = (size_t)3 * tw * th;
    float* out = (float*)aligned_alloc(64, n * sizeof(float));
    if (!out) return NULL;
    const float mean[3] = {0.485f, 0.456f, 0.406f};
    const float stdv[3] = {0.229f, 0.224f, 0.225f};
    for (int y = 0; y < th; y++) {
        float sy = (h <= 1) ? 0.0f : ((float)y + 0.5f) * (float)h / (float)th - 0.5f;
        int iy0 = (int)floorf(sy), iy1 = iy0 + 1;
        float fy = sy - iy0;
        if (iy0 < 0) iy0 = 0; if (iy1 < 0) iy1 = 0;
        if (iy0 >= h) iy0 = h - 1; if (iy1 >= h) iy1 = h - 1;
        for (int x = 0; x < tw; x++) {
            float sx = (w <= 1) ? 0.0f : ((float)x + 0.5f) * (float)w / (float)tw - 0.5f;
            int ix0 = (int)floorf(sx), ix1 = ix0 + 1;
            float fx = sx - ix0;
            if (ix0 < 0) ix0 = 0; if (ix1 < 0) ix1 = 0;
            if (ix0 >= w) ix0 = w - 1; if (ix1 >= w) ix1 = w - 1;
            const uint8_t* a = src + 3 * (iy0 * w + ix0);
            const uint8_t* b = src + 3 * (iy0 * w + ix1);
            const uint8_t* c = src + 3 * (iy1 * w + ix0);
            const uint8_t* d = src + 3 * (iy1 * w + ix1);
            float r = (a[0]*(1-fx)+b[0]*fx)*(1-fy) + (c[0]*(1-fx)+d[0]*fx)*fy;
            float g = (a[1]*(1-fx)+b[1]*fx)*(1-fy) + (c[1]*(1-fx)+d[1]*fx)*fy;
            float bl= (a[2]*(1-fx)+b[2]*fx)*(1-fy) + (c[2]*(1-fx)+d[2]*fx)*fy;
            // 通道序校准：det 与 rec 共用本函数，两路必须一致。
            if (g_channel_bgr) { float t = r; r = bl; bl = t; }
            // NCHW：平面大小 plane=H*W，通道 c 数据位于 [c*plane + y*W + x]
            int plane = th * tw;
            int idx = y * tw + x;
            if (do_norm) {
                out[idx + 0*plane] = (r / 255.0f - mean[0]) / stdv[0];
                out[idx + 1*plane] = (g / 255.0f - mean[1]) / stdv[1];
                out[idx + 2*plane] = (bl/ 255.0f - mean[2]) / stdv[2];
            } else {
                out[idx + 0*plane] = r / 255.0f;
                out[idx + 1*plane] = g / 255.0f;
                out[idx + 2*plane] = bl / 255.0f;
            }
        }
    }
    return out;
}

// ============================================================
// det 预处理：限制最长边 736，保持比例，pad 到 32 倍数
// ============================================================
static float* preprocess_det(const uint8_t* rgb, int w, int h,
                             int* out_tw, int* out_th, float* out_factor) {
    const int limit = 736;
    float factor = 1.0f;
    int nw = w, nh = h;
    int maxs = (w > h) ? w : h;
    if (maxs > limit) { factor = (float)limit / (float)maxs; nw = (int)(w*factor); nh = (int)(h*factor); }
    int tw = ((nw + 31) / 32) * 32;
    int th = ((nh + 31) / 32) * 32;
    if (tw < 32) tw = 32; if (th < 32) th = 32;
    float* f = resize_rgb(rgb, w, h, tw, th, 0);
    *out_tw = tw; *out_th = th; *out_factor = factor;
    return f;
}

// 连通域（8 连接）求轴对齐框；out_boxes 预分配 (max_boxes*4)
static int find_boxes(const float* prob, int mw, int mh, float thr,
                      int* boxes, int max_boxes) {
    unsigned char* vis = (unsigned char*)calloc((size_t)mw*mh, 1);
    if (!vis) return 0;
    int nb = 0;
    const int dx[8] = {-1,0,1,-1,1,-1,0,1};
    const int dy[8] = {-1,-1,-1,0,0,1,1,1};
    int* stack = (int*)malloc(sizeof(int) * (size_t)mw * mh);
    if (!stack) { free(vis); return 0; }
    for (int y = 0; y < mh && nb < max_boxes; y++) {
        for (int x = 0; x < mw && nb < max_boxes; x++) {
            int idx = y*mw + x;
            if (vis[idx] || prob[idx] < thr) continue;
            int sp = 0;
            stack[sp++] = idx; vis[idx] = 1;
            int x0=x,y0=y,x1=x,y1=y;
            int area=0;
            while (sp > 0) {
                int cur = stack[--sp]; area++;
                int cy = cur / mw, cx = cur % mw;
                if (cx < x0) { x0 = cx; }
                if (cx > x1) { x1 = cx; }
                if (cy < y0) { y0 = cy; }
                if (cy > y1) { y1 = cy; }
                for (int k=0;k<8;k++) {
                    int nx=cx+dx[k], ny=cy+dy[k];
                    if (nx<0||ny<0||nx>=mw||ny>=mh) continue;
                    int ni=ny*mw+nx;
                    if (vis[ni]||prob[ni]<thr) continue;
                    vis[ni]=1; stack[sp++]=ni;
                }
            }
            if (area >= 10) {
                boxes[nb*4+0]=x0; boxes[nb*4+1]=y0;
                boxes[nb*4+2]=x1; boxes[nb*4+3]=y1;
                nb++;
            }
        }
    }
    free(stack);
    free(vis);
    return nb;
}

// ============================================================
// B1 · 旋转四边形后处理（凸包 + 旋转卡壳 + Unclip + 透视裁剪）
//
// 为什么不用通用 Vatti：DB 的连通域在真实扫描件上绝大多数是凸的
// 文本行；对**凸四边形**，把 4 条边各自沿外法线平移 d 再求相邻交点，
// 与 Vatti 的多边形等距外扩结果一致，且实现只有几十行、无第三方依赖。
// 任意凹多边形 / 粘连文本行仍回退轴对齐路径（如实标注，不夸大）。
// ============================================================
typedef struct { float x, y; } OcrPt;
typedef struct { OcrPt p[4]; } OcrQuad;

static float ocr_cross(OcrPt a, OcrPt b, OcrPt c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

/** Andrew monotone chain；out 至少 2*n */
static int convex_hull(const OcrPt* in, int n, OcrPt* out) {
    if (n < 3) { for (int i = 0; i < n; i++) out[i] = in[i]; return n; }
    OcrPt* tmp = (OcrPt*)malloc(sizeof(OcrPt) * (size_t)n);
    if (!tmp) return 0;
    memcpy(tmp, in, sizeof(OcrPt) * (size_t)n);
    for (int i = 1; i < n; i++) {
        OcrPt k = tmp[i]; int j = i - 1;
        while (j >= 0 && (tmp[j].x > k.x || (tmp[j].x == k.x && tmp[j].y > k.y))) {
            tmp[j + 1] = tmp[j]; j--;
        }
        tmp[j + 1] = k;
    }
    int m = 0;
    for (int i = 0; i < n; i++) {
        while (m >= 2 && ocr_cross(out[m-2], out[m-1], tmp[i]) <= 0) m--;
        out[m++] = tmp[i];
    }
    int lower = m;
    for (int i = n - 2; i >= 0; i--) {
        while (m > lower && ocr_cross(out[m-2], out[m-1], tmp[i]) <= 0) m--;
        out[m++] = tmp[i];
    }
    if (m > 1) m--;
    free(tmp);
    return m;
}

/**
 * 最小面积外接矩形：枚举凸包的每条边作为方向，取面积最小者。
 * 输出 p[0]→p[1] 保证是**长边**（rec 模型只认水平文本行），
 * 顺序 p0(左上)→p1(右上)→p2(右下)→p3(左下) 供透视变换使用。
 */
static OcrQuad min_area_rect(const OcrPt* hull, int n) {
    OcrQuad best; memset(&best, 0, sizeof(best));
    float min_area = 1e30f;
    for (int i = 0; i < n; i++) {
        OcrPt a = hull[i], b = hull[(i + 1) % n];
        float ex = b.x - a.x, ey = b.y - a.y;
        float len = sqrtf(ex * ex + ey * ey);
        if (len < 1e-6f) continue;
        float ux = ex / len, uy = ey / len;   // 沿边
        float vx = -uy, vy = ux;             // 法向
        float minu = 1e30f, maxu = -1e30f, minv = 1e30f, maxv = -1e30f;
        for (int j = 0; j < n; j++) {
            float u = hull[j].x * ux + hull[j].y * uy;
            float v = hull[j].x * vx + hull[j].y * vy;
            if (u < minu) minu = u;
            if (u > maxu) maxu = u;
            if (v < minv) minv = v;
            if (v > maxv) maxv = v;
        }
        float wu = maxu - minu, wv = maxv - minv;
        float area = wu * wv;
        if (area >= min_area) continue;
        min_area = area;
        // (u,v) -> 原坐标（正交单位基的线性组合）
        #define OCR_P(U, V) (OcrPt){ (U)*ux + (V)*vx, (U)*uy + (V)*vy }
        if (wu >= wv) {
            best.p[0] = OCR_P(minu, minv); best.p[1] = OCR_P(maxu, minv);
            best.p[2] = OCR_P(maxu, maxv); best.p[3] = OCR_P(minu, maxv);
        } else {
            // 长边在 v 方向：顺时针转一下顶点顺序，让 p0→p1 是长边
            best.p[0] = OCR_P(minu, minv); best.p[1] = OCR_P(minu, maxv);
            best.p[2] = OCR_P(maxu, maxv); best.p[3] = OCR_P(maxu, minv);
        }
        #undef OCR_P
    }
    return best;
}

/** 两条直线 a+t*e 与 b+s*f 的交点；平行时退化为 a+e */
static OcrPt line_intersect(OcrPt a, OcrPt e, OcrPt b, OcrPt f) {
    float den = e.x * f.y - e.y * f.x;
    if (fabsf(den) < 1e-6f) return (OcrPt){ a.x + e.x, a.y + e.y };
    float t = ((b.x - a.x) * f.y - (b.y - a.y) * f.x) / den;
    return (OcrPt){ a.x + t * e.x, a.y + t * e.y };
}

/**
 * 规整四边形顶点方向。
 *
 * 【为什么必须有】旋转卡壳枚举的是**凸包的边**，边的朝向由凸包绕序决定，
 * 是任意的：同一块文本在不同倾斜角下，p0→p1 可能指向左，p1→p2 可能
 * 指向上。若直接拿去做透视变换，裁出的图会左右镜像 / 上下颠倒，
 * rec 模型一个字都认不出（B3 倾斜 12° 夹具实测：QUAD=1 三个框全空，
 * QUAD=0 三个框全中 —— 正是这个原因）。
 *
 * 做法：枚举 4 个起点 × 2 种绕序共 8 种顶点排列，只保留「长边在
 * p0→p1」的候选，再取 p0→p1 最水平向右、p1→p2 最竖直向下的一种。
 */
static OcrQuad orient_quad(OcrQuad q) {
    OcrQuad best = q;
    float bestScore = -1e30f;
    for (int shift = 0; shift < 4; shift++) {
        for (int dir = 0; dir < 2; dir++) {
            OcrQuad c;
            for (int k = 0; k < 4; k++) {
                int idx = (dir == 0) ? (shift + k) % 4 : (shift + 4 - k) % 4;
                c.p[k] = q.p[idx];
            }
            float d1x = c.p[1].x - c.p[0].x, d1y = c.p[1].y - c.p[0].y;
            float d2x = c.p[2].x - c.p[1].x, d2y = c.p[2].y - c.p[1].y;
            float l1 = sqrtf(d1x*d1x + d1y*d1y);
            float l2 = sqrtf(d2x*d2x + d2y*d2y);
            if (l1 < l2 - 0.5f) { continue; }   // 长边必须是 p0→p1
            float score = d1x + d2y - 1.5f * fabsf(d1y);
            if (score > bestScore) { bestScore = score; best = c; }
        }
    }
    return best;
}

/**
 * Unclip：d = area * ratio / perimeter（PaddleOCR 同款），
 * 4 条边各沿外法线平移 d，取相邻偏移线交点作为新顶点。
 * 外法线方向用「远离质心」判定，避免依赖顶点绕序约定。
 */
static OcrQuad unclip_quad(OcrQuad q, float ratio) {
    float perimeter = 0.0f, area2 = 0.0f;
    OcrPt c = {0.0f, 0.0f};
    for (int i = 0; i < 4; i++) {
        OcrPt a = q.p[i], b = q.p[(i + 1) % 4];
        perimeter += sqrtf((b.x-a.x)*(b.x-a.x) + (b.y-a.y)*(b.y-a.y));
        area2 += a.x * b.y - b.x * a.y;
        c.x += a.x; c.y += a.y;
    }
    c.x /= 4.0f; c.y /= 4.0f;
    float area = fabsf(area2) * 0.5f;
    if (perimeter < 1e-3f || area < 1e-3f) return q;
    float d = area * ratio / perimeter;
    OcrPt A[4], E[4];
    for (int i = 0; i < 4; i++) {
        OcrPt a = q.p[i], b = q.p[(i + 1) % 4];
        float dx = b.x - a.x, dy = b.y - a.y;
        float len = sqrtf(dx*dx + dy*dy);
        if (len < 1e-6f) { A[i] = a; E[i] = (OcrPt){1.0f, 0.0f}; continue; }
        float nx = -dy / len, ny = dx / len;
        float mx = (a.x + b.x) * 0.5f, my = (a.y + b.y) * 0.5f;
        float plus  = (mx+nx-c.x)*(mx+nx-c.x) + (my+ny-c.y)*(my+ny-c.y);
        float minus = (mx-nx-c.x)*(mx-nx-c.x) + (my-ny-c.y)*(my-ny-c.y);
        if (plus < minus) { nx = -nx; ny = -ny; }
        A[i] = (OcrPt){ a.x + d*nx, a.y + d*ny };
        E[i] = (OcrPt){ dx, dy };
    }
    OcrQuad o;
    for (int i = 0; i < 4; i++) {
        int prev = (i + 3) % 4;
        o.p[i] = line_intersect(A[prev], E[prev], A[i], E[i]);
    }
    return o;
}

/**
 * 求单应：目标 (0,0),(W,0),(W,H),(0,H) → 源 quad.p[0..3]。
 * 8 元线性方程组高斯消元；奇异（退化四边形）返回 0。
 */
static int perspective_coeff(const OcrQuad* q, float W, float H, float m[9]) {
    const float u[4] = {0.0f, W, W, 0.0f};
    const float v[4] = {0.0f, 0.0f, H, H};
    float A[8][9]; memset(A, 0, sizeof(A));
    for (int i = 0; i < 4; i++) {
        float x = q->p[i].x, y = q->p[i].y, uu = u[i], vv = v[i];
        A[2*i][0]=uu;   A[2*i][1]=vv;   A[2*i][2]=1.0f;
        A[2*i][6]=-x*uu; A[2*i][7]=-x*vv; A[2*i][8]=x;
        A[2*i+1][3]=uu; A[2*i+1][4]=vv; A[2*i+1][5]=1.0f;
        A[2*i+1][6]=-y*uu; A[2*i+1][7]=-y*vv; A[2*i+1][8]=y;
    }
    for (int col = 0; col < 8; col++) {
        int piv = col;
        for (int r = col+1; r < 8; r++)
            if (fabsf(A[r][col]) > fabsf(A[piv][col])) piv = r;
        if (fabsf(A[piv][col]) < 1e-8f) return 0;
        if (piv != col)
            for (int c2 = 0; c2 < 9; c2++) { float t=A[piv][c2]; A[piv][c2]=A[col][c2]; A[col][c2]=t; }
        float dv = A[col][col];
        for (int c2 = col; c2 < 9; c2++) A[col][c2] /= dv;
        for (int r = 0; r < 8; r++) {
            if (r == col) continue;
            float f = A[r][col];
            if (f == 0.0f) continue;
            for (int c2 = col; c2 < 9; c2++) A[r][c2] -= f * A[col][c2];
        }
    }
    for (int i = 0; i < 8; i++) m[i] = A[i][8];
    m[8] = 1.0f;
    return 1;
}

/** 透视 + 双线性采样：把任意四边形拉成 tw×th 的水平 RGB 图 */
static uint8_t* warp_quad_rgb(const uint8_t* rgb, int w, int h,
                              const OcrQuad* q, int tw, int th) {
    float m[9];
    if (!perspective_coeff(q, (float)tw, (float)th, m)) return NULL;
    uint8_t* out = (uint8_t*)calloc((size_t)3 * tw * th, 1);
    if (!out) return NULL;
    for (int y = 0; y < th; y++) {
        for (int x = 0; x < tw; x++) {
            float u = (float)x + 0.5f, v = (float)y + 0.5f;
            float den = m[6]*u + m[7]*v + 1.0f;
            if (fabsf(den) < 1e-6f) continue;
            float sx = (m[0]*u + m[1]*v + m[2]) / den;
            float sy = (m[3]*u + m[4]*v + m[5]) / den;
            if (sx < 0) { sx = 0; }
            if (sx > w - 1) { sx = (float)(w - 1); }
            if (sy < 0) { sy = 0; }
            if (sy > h - 1) { sy = (float)(h - 1); }
            int ix0 = (int)floorf(sx), iy0 = (int)floorf(sy);
            int ix1 = (ix0 + 1 < w) ? ix0 + 1 : w - 1;
            int iy1 = (iy0 + 1 < h) ? iy0 + 1 : h - 1;
            float fx = sx - ix0, fy = sy - iy0;
            const uint8_t* pa = rgb + 3*(iy0*w + ix0);
            const uint8_t* pb = rgb + 3*(iy0*w + ix1);
            const uint8_t* pc = rgb + 3*(iy1*w + ix0);
            const uint8_t* pd = rgb + 3*(iy1*w + ix1);
            for (int c = 0; c < 3; c++) {
                float top = pa[c]*(1-fx) + pb[c]*fx;
                float bot = pc[c]*(1-fx) + pd[c]*fx;
                float val = top*(1-fy) + bot*fy;
                if (val < 0) val = 0; if (val > 255) val = 255;
                out[3*(y*tw + x) + c] = (uint8_t)(val + 0.5f);
            }
        }
    }
    return out;
}

/**
 * 连通域 → 旋转四边形。复用 find_boxes 的 BFS，入栈过的全部像素
 * 即连通域点集（stack[0..total)），无需额外存坐标。
 * 结果按中心 y 升序，保证输出文本顺序与阅读顺序一致。
 */
static int find_quads(const float* prob, int mw, int mh, float thr,
                      OcrQuad* quads, int max_quads) {
    size_t npix = (size_t)mw * mh;
    unsigned char* vis  = (unsigned char*)calloc(npix, 1);
    int*    stack = (int*)malloc(sizeof(int) * npix);    // DFS 栈（会弹出）
    int*    comp  = (int*)malloc(sizeof(int) * npix);    // 本连通域全部像素（只追加）
    OcrPt*  pts   = (OcrPt*)malloc(sizeof(OcrPt) * npix);
    OcrPt*  hull  = (OcrPt*)malloc(sizeof(OcrPt) * npix * 2);
    if (!vis || !stack || !comp || !pts || !hull) {
        free(vis); free(stack); free(comp); free(pts); free(hull);
        return 0;
    }
    const int dx[8] = {-1,0,1,-1,1,-1,0,1};
    const int dy[8] = {-1,-1,-1,0,0,1,1,1};
    int nb = 0;
    for (int y = 0; y < mh && nb < max_quads; y++) {
        for (int x = 0; x < mw && nb < max_quads; x++) {
            int idx = y*mw + x;
            if (vis[idx] || prob[idx] < thr) continue;
            int sp = 0, total = 0;
            stack[sp++] = idx; comp[total++] = idx; vis[idx] = 1;
            int x0=x,y0=y,x1=x,y1=y;
            while (sp > 0) {
                int cur = stack[--sp];
                int cy = cur / mw, cx = cur % mw;
                if (cx < x0) { x0 = cx; }
                if (cx > x1) { x1 = cx; }
                if (cy < y0) { y0 = cy; }
                if (cy > y1) { y1 = cy; }
                for (int k = 0; k < 8; k++) {
                    int nx=cx+dx[k], ny=cy+dy[k];
                    if (nx<0||ny<0||nx>=mw||ny>=mh) continue;
                    int ni=ny*mw+nx;
                    if (vis[ni]||prob[ni]<thr) continue;
                    vis[ni]=1;
                    stack[sp++]=ni;
                    comp[total++]=ni;
                }
            }
            if (total < 10) continue;
            for (int k = 0; k < total; k++) {
                pts[k].x = (float)(comp[k] % mw);
                pts[k].y = (float)(comp[k] / mw);
            }
            int hn = convex_hull(pts, total, hull);
            OcrQuad q;
            if (hn >= 3) {
                q = min_area_rect(hull, hn);
            } else {
                // 退化成一条线 / 单点：用轴对齐框，保证不丢文本
                q.p[0]=(OcrPt){(float)x0,(float)y0};
                q.p[1]=(OcrPt){(float)x1,(float)y0};
                q.p[2]=(OcrPt){(float)x1,(float)y1};
                q.p[3]=(OcrPt){(float)x0,(float)y1};
            }
            // 方向规整：不镜像、不颠倒，否则 rec 全空（见 orient_quad 注释）
            quads[nb++] = orient_quad(q);
        }
    }
    // 按中心 y 升序（同一行再按 x），使输出顺序贴合阅读顺序
    for (int i = 1; i < nb; i++) {
        OcrQuad key = quads[i];
        float ky = (key.p[0].y+key.p[1].y+key.p[2].y+key.p[3].y)*0.25f;
        float kx = (key.p[0].x+key.p[1].x+key.p[2].x+key.p[3].x)*0.25f;
        int j = i - 1;
        while (j >= 0) {
            OcrQuad o = quads[j];
            float oy = (o.p[0].y+o.p[1].y+o.p[2].y+o.p[3].y)*0.25f;
            float ox = (o.p[0].x+o.p[1].x+o.p[2].x+o.p[3].x)*0.25f;
            // 2 像素内视作同一行
            if (oy < ky - 2.0f || (fabsf(oy - ky) <= 2.0f && ox <= kx)) break;
            quads[j+1] = quads[j];
            j--;
        }
        quads[j+1] = key;
    }
    free(stack); free(comp); free(vis); free(pts); free(hull);
    return nb;
}

// ============================================================
// CTC 贪心解码（rec 输出 [1,T,C]）
// ============================================================
static void ctc_decode(const float* logits, int T, int C, char* out, int out_cap) {
    int pos = 0;
    int prev = -1;
    for (int t = 0; t < T; t++) {
        int best = 0; float bv = logits[t*C + 0];
        for (int c = 1; c < C; c++) {
            float v = logits[t*C + c];
            if (v > bv) { bv = v; best = c; }
        }
        if (best == 0) { prev = 0; continue; }      // blank
        if (best == prev) continue;                   // 重复
        char ch[8]; int cl = 0;
        if (best == C - 1 && g_dict_len + 2 == C) {
            ch[0] = ' '; cl = 1;
        } else if (best - 1 < g_dict_len) {
            const char* d = g_dict[best - 1];
            cl = (int)strlen(d);
            if (cl > 7) cl = 7;
            memcpy(ch, d, cl);
        } else {
            ch[0] = '?'; cl = 1;
        }
        if (pos + cl + 1 < out_cap) {
            memcpy(out + pos, ch, cl); pos += cl;
        }
        prev = best;
    }
    out[pos] = 0;
}

// ============================================================
// 对外 ABI（零参 init，路径走环境变量）
// ============================================================
int ams_ocr_init(void) {
    // ---- 运行时可调参数（B1/B2）----
    // 通道序默认 rgb：本模型是 web 导出版，灰度与彩色夹具均以 RGB 验证通过。
    // 其它导出版本若期望 BGR，由运维显式设 AMS_OCR_CHANNEL_ORDER=bgr，
    // 不做隐式猜测（猜错会静默降低识别率，比报错更难排查）。
    const char* co = getenv("AMS_OCR_CHANNEL_ORDER");
    g_channel_bgr = (co && (co[0] == 'b' || co[0] == 'B')) ? 1 : 0;
    const char* qu = getenv("AMS_OCR_DET_QUAD");
    g_use_quad = (qu && qu[0] == '0') ? 0 : 1;
    const char* ur = getenv("AMS_OCR_UNCLIP_RATIO");
    if (ur) {
        float v = (float)atof(ur);
        if (v > 0.5f && v < 5.0f) g_unclip_ratio = v;
    }
    fprintf(stderr, "[ocr_bridge] config quad=%d bgr=%d unclip=%.2f\n",
            g_use_quad, g_channel_bgr, g_unclip_ratio);

    const char* det = getenv("AMS_OCR_DET");
    const char* rec = getenv("AMS_OCR_REC");
    const char* dict = getenv("AMS_OCR_DICT");
    if (!det || !rec || !dict) {
        fprintf(stderr, "[ocr_bridge] init skipped: missing AMS_OCR_DET/REC/DICT\n");
        return -1;
    }
    if (!g_ort) {
        const OrtApiBase* base = OrtGetApiBase();
        if (!base) return fail("OrtGetApiBase");
        g_ort = base->GetApi(ORT_API_VERSION);
        if (!g_ort) return fail("GetApi");
    }
    OrtStatus* st;
    if ((st = g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "ams_ocr", &g_env)) != NULL) {
        const char* m = g_ort->GetErrorMessage(st); fprintf(stderr,"[ocr_bridge] %s\n", m); g_ort->ReleaseStatus(st);
        return fail("CreateEnv");
    }
    if ((st = g_ort->CreateSessionOptions(&g_opt)) != NULL) { g_ort->ReleaseStatus(st); return fail("CreateSessionOptions"); }
    g_ort->SetIntraOpNumThreads(g_opt, 4);

    if ((st = g_ort->CreateSession(g_env, det, g_opt, &g_det)) != NULL) {
        fprintf(stderr,"[ocr_bridge] det: %s\n", g_ort->GetErrorMessage(st)); g_ort->ReleaseStatus(st); return fail("CreateSession det");
    }
    if ((st = g_ort->CreateSession(g_env, rec, g_opt, &g_rec)) != NULL) {
        fprintf(stderr,"[ocr_bridge] rec: %s\n", g_ort->GetErrorMessage(st)); g_ort->ReleaseStatus(st); return fail("CreateSession rec");
    }
    OrtAllocator* alloc = NULL;
    g_ort->GetAllocatorWithDefaultOptions(&alloc);
    g_ort->SessionGetInputName(g_det, 0, alloc, &g_det_in);
    g_ort->SessionGetOutputName(g_det, 0, alloc, &g_det_out);
    g_ort->SessionGetInputName(g_rec, 0, alloc, &g_rec_in);
    g_ort->SessionGetOutputName(g_rec, 0, alloc, &g_rec_out);

    if (load_dict(dict) != 0) return fail("load_dict");
    fprintf(stderr, "[ocr_bridge] init OK (det+rec sessions, dict %d)\n", g_dict_len);
    return 0;
}

// 主流程：传入已解码 RGB 像素，输出纯文本（换行分隔）
/**
 * 对一块已裁好的 RGB 图跑 rec 模型 + CTC 解码。
 * 旋转框路径与轴对齐回退路径共用，避免两处推理逻辑漂移。
 * 返回识别出的字节数（0 = 空）。
 */
static int run_rec_crop(const uint8_t* crop, int bw, int bh,
                        OrtMemoryInfo* mi, char* text, int text_cap) {
    if (!crop || bw < 4 || bh < 4) return 0;
    int rth = 48;
    int rtw = (int)((float)rth * (float)bw / (float)bh);
    if (rtw < 48) rtw = 48;
    if (rtw > 320) rtw = 320;
    float* rec_in = resize_rgb(crop, bw, bh, rtw, rth, 0);
    if (!rec_in) return 0;
    OrtStatus* st = NULL;
    int64_t rec_dims[4] = {1, 3, rth, rtw};
    OrtValue* rec_val = NULL;
    if ((st = g_ort->CreateTensorWithDataAsOrtValue(mi, rec_in,
            (size_t)3*rth*rtw*sizeof(float), rec_dims, 4,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &rec_val)) != NULL) {
        g_ort->ReleaseStatus(st); free(rec_in); return 0;
    }
    const char* rec_in_names[1] = {g_rec_in};
    const char* rec_out_names[1] = {g_rec_out};
    OrtValue* rec_out_val = NULL;
    if ((st = g_ort->Run(g_rec, NULL, rec_in_names, (const OrtValue**)&rec_val, 1,
            rec_out_names, 1, &rec_out_val)) != NULL) {
        g_ort->ReleaseStatus(st);
        g_ort->ReleaseValue(rec_val); free(rec_in); return 0;
    }
    int ok = 0;
    int64_t rdims[3]; size_t rnd;
    if (read_dims(g_rec, rec_out_val, rdims, &rnd) == 0) {
        int T, C;
        if (rdims[2] > rdims[1]) { T = (int)rdims[1]; C = (int)rdims[2]; }
        else { T = (int)rdims[2]; C = (int)rdims[1]; }
        g_rec_classes = C;
        float* rl = NULL;
        g_ort->GetTensorMutableData(rec_out_val, (void**)&rl);
        if (rl) {
            ctc_decode(rl, T, C, text, text_cap);
            ok = (int)strlen(text);
        }
    }
    g_ort->ReleaseValue(rec_out_val);
    g_ort->ReleaseValue(rec_val);
    free(rec_in);
    return ok;
}

static float quad_dist(OcrPt a, OcrPt b) {
    return sqrtf((b.x-a.x)*(b.x-a.x) + (b.y-a.y)*(b.y-a.y));
}

static int ocr_pipeline(const uint8_t* rgb, int w, int h, char* out_text, int out_cap) {
    if (!g_det || !g_rec) return fail("not initialized");
    if (out_cap <= 0 || !out_text) return -1;
    OrtStatus* st;
    int rc = -1;

    int tw, th; float factor;
    float* det_in = preprocess_det(rgb, w, h, &tw, &th, &factor);
    if (!det_in) return fail("det preprocess alloc");

    int64_t det_dims[4] = {1, 3, th, tw};
    OrtMemoryInfo* mi = NULL;
    g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mi);
    OrtValue* det_val = NULL;
    if ((st = g_ort->CreateTensorWithDataAsOrtValue(mi, det_in, (size_t)3*tw*th*sizeof(float),
            det_dims, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &det_val)) != NULL) {
        g_ort->ReleaseStatus(st); goto det_cleanup;
    }
    const char* det_in_names[1] = {g_det_in};
    const char* det_out_names[1] = {g_det_out};
    OrtValue* det_out_val = NULL;
    if ((st = g_ort->Run(g_det, NULL, det_in_names, (const OrtValue**)&det_val, 1,
            det_out_names, 1, &det_out_val)) != NULL) {
        g_ort->ReleaseStatus(st); goto det_cleanup;
    }
    int64_t ddims[4]; size_t dnd;
    if (read_dims(g_det, det_out_val, ddims, &dnd) != 0) goto det_cleanup;
    int mh = (int)ddims[2], mw = (int)ddims[3];
    float* prob = NULL;
    g_ort->GetTensorMutableData(det_out_val, (void**)&prob);
    if (!prob) goto det_cleanup;
    // 自适应 sigmoid：若输出为 logits（最大值 > 1.5）则转概率
    float pmax = 0.0f;
    long total = (long)mw * mh;
    for (long k = 0; k < total; k++) { if (prob[k] > pmax) pmax = prob[k]; }
    if (pmax > 1.5f) {
        for (long k = 0; k < total; k++) prob[k] = 1.0f / (1.0f + expf(-prob[k]));
    }

    int boxes[400*4];
    OcrQuad quads[400];
    int nb = 0;
    if (g_use_quad) {
        nb = find_quads(prob, mw, mh, 0.3f, quads, 400);
    } else {
        nb = find_boxes(prob, mw, mh, 0.3f, boxes, 400);
    }
    fprintf(stderr, "[ocr_bridge] det found %d boxes (map %dx%d, quad=%d)\n",
            nb, mw, mh, g_use_quad);

    // 输出缓冲（纯文本，换行分隔）
    char* combined = (char*)malloc(out_cap > 0 ? out_cap : 65536);
    int comb_cap = (out_cap > 0 ? out_cap : 65536);
    int comb_len = 0;
    combined[0] = 0;

    float sx = (mw > 0) ? (float)tw / (float)mw : 1.0f;
    float sy = (mh > 0) ? (float)th / (float)mh : 1.0f;

    for (int i = 0; i < nb; i++) {
        uint8_t* crop = NULL;
        int bw = 0, bh = 0;
        if (g_use_quad) {
            // ---- 旋转框路径：映射回原图 → Unclip → 透视拉平 ----
            OcrQuad q = quads[i];
            for (int k = 0; k < 4; k++) {
                q.p[k].x *= sx / factor;
                q.p[k].y *= sy / factor;
            }
            q = unclip_quad(q, g_unclip_ratio);
            for (int k = 0; k < 4; k++) {
                if (q.p[k].x < 0) q.p[k].x = 0;
                if (q.p[k].y < 0) q.p[k].y = 0;
                if (q.p[k].x > w) q.p[k].x = (float)w;
                if (q.p[k].y > h) q.p[k].y = (float)h;
            }
            float long_side  = quad_dist(q.p[0], q.p[1]);
            float short_side = quad_dist(q.p[1], q.p[2]);
            if (long_side < 8.0f || short_side < 4.0f) continue;
            int recw = (int)(48.0f * long_side / short_side);
            if (recw < 48) recw = 48;
            if (recw > 320) recw = 320;
            // warp 输出尺寸即 rec 输入尺寸；run_rec_crop 里再做一次 1:1
            // resize（恒等变换），两条路径因此共用同一段推理代码。
            crop = warp_quad_rgb(rgb, w, h, &q, recw, 48);
            if (!crop) continue;   // 退化四边形（单应奇异）不重复输出
            bw = recw; bh = 48;
        } else {
            // ---- 旧轴对齐路径（AMS_OCR_DET_QUAD=0 时零回归）----
            int mx0=boxes[i*4+0], my0=boxes[i*4+1], mx1=boxes[i*4+2], my1=boxes[i*4+3];
            int ox0=(int)((float)mx0*sx/factor), oy0=(int)((float)my0*sy/factor);
            int ox1=(int)((float)(mx1+1)*sx/factor), oy1=(int)((float)(my1+1)*sy/factor);
            int ex = (int)(0.02*(float)w)+2;
            ox0-=ex; oy0-=ex; ox1+=ex; oy1+=ex;
            if (ox0<0)ox0=0; if(oy0<0)oy0=0; if(ox1>w)ox1=w; if(oy1>h)oy1=h;
            bw=ox1-ox0; bh=oy1-oy0;
            if (bw<4||bh<4) continue;
            crop = (uint8_t*)malloc((size_t)3*bw*bh);
            if (!crop) continue;
            for (int yy=0; yy<bh; yy++) {
                memcpy(crop+3*yy*bw, rgb+3*((oy0+yy)*w+ox0), (size_t)3*bw);
            }
        }
        char text[4096]; text[0] = 0;
        int tl = run_rec_crop(crop, bw, bh, mi, text, (int)sizeof(text));
        free(crop);
        fprintf(stderr, "[ocr_bridge] box[%d] -> \"%s\"\n", i, text);
        if (tl <= 0) continue;
        if (comb_len + tl + 2 < comb_cap) {
            if (comb_len>0) combined[comb_len++]='\n';
            memcpy(combined+comb_len, text, tl); comb_len+=tl; combined[comb_len]=0;
        }
    }

    int written = (comb_len < out_cap) ? comb_len : out_cap;
    memcpy(out_text, combined, written);
    if (written < out_cap) out_text[written] = 0;
    free(combined);
    rc = written;

det_cleanup:
    if (det_out_val) g_ort->ReleaseValue(det_out_val);
    if (det_val) g_ort->ReleaseValue(det_val);
    if (mi) g_ort->ReleaseMemoryInfo(mi);
    free(det_in);
    return rc;
}

int ams_ocr_run(const uint8_t* rgb, int w, int h, char* out_text, int out_cap) {
    return ocr_pipeline(rgb, w, h, out_text, out_cap);
}

int ams_ocr_free(void) {
    if (g_det_out) free(g_det_out);
    if (g_det_in) free(g_det_in);
    if (g_rec_out) free(g_rec_out);
    if (g_rec_in) free(g_rec_in);
    if (g_rec) { g_ort->ReleaseSession(g_rec); g_rec=NULL; }
    if (g_det) { g_ort->ReleaseSession(g_det); g_det=NULL; }
    if (g_opt) { g_ort->ReleaseSessionOptions(g_opt); g_opt=NULL; }
    if (g_env) { g_ort->ReleaseEnv(g_env); g_env=NULL; }
    for (int i=0;i<g_dict_len;i++) free(g_dict[i]);
    if (g_dict) free(g_dict);
    g_dict=NULL; g_dict_len=0;
    g_ort=NULL;
    fprintf(stderr, "[ocr_bridge] freed\n");
    return 0;
}
