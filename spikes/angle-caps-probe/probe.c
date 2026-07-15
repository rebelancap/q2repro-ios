// ANGLE-Metal capability probe (host macOS — the Metal backend caps code in
// DisplayMtl.mm is shared with iOS, so the SSBO/texture-buffer verdict here is
// the same one the iPhone would report).
//
// Creates an ES 3.1 context on ANGLE's Metal backend and prints the exact limits
// q2repro's MD5 GPU-skeletal gate checks: GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS
// (needs >=2, models.c/main.c) and GL_MAX_TEXTURE_BUFFER_SIZE (buffer-texture
// fallback). If both are 0/absent, ANGLE-Metal cannot run MD5 → CPU skinning
// required regardless of substrate.
#include <stdio.h>
#include <string.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

static GLint geti(GLenum e){ GLint v=-1; glGetIntegerv(e,&v); return v; }

int main(void){
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if(!getPlatformDisplay){ printf("no eglGetPlatformDisplayEXT\n"); return 1; }

    EGLint dattrs[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void*)EGL_DEFAULT_DISPLAY, dattrs);
    if(dpy==EGL_NO_DISPLAY){ printf("no display\n"); return 1; }
    EGLint major,minor;
    if(!eglInitialize(dpy,&major,&minor)){ printf("eglInitialize failed 0x%x\n", eglGetError()); return 1; }
    printf("EGL %d.%d  vendor=%s\n", major,minor, eglQueryString(dpy,EGL_VENDOR));

    EGLint cfgattr[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                         EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE };
    EGLConfig cfg; EGLint n=0;
    if(!eglChooseConfig(dpy,cfgattr,&cfg,1,&n)||n<1){ printf("no config\n"); return 1; }
    EGLint pb[]={EGL_WIDTH,16,EGL_HEIGHT,16,EGL_NONE};
    EGLSurface surf = eglCreatePbufferSurface(dpy,cfg,pb);
    EGLint a31[] = { EGL_CONTEXT_MAJOR_VERSION,3, EGL_CONTEXT_MINOR_VERSION,1, EGL_NONE };
    EGLint a30[] = { EGL_CONTEXT_MAJOR_VERSION,3, EGL_CONTEXT_MINOR_VERSION,0, EGL_NONE };
    int gotMinor = 1;
    EGLContext ctx = eglCreateContext(dpy,cfg,EGL_NO_CONTEXT,a31);
    if(ctx==EGL_NO_CONTEXT){
        printf("ES 3.1 context: REFUSED (eglError 0x%x) -> ANGLE-Metal does not expose ES 3.1\n", eglGetError());
        ctx = eglCreateContext(dpy,cfg,EGL_NO_CONTEXT,a30); gotMinor = 0;
        if(ctx==EGL_NO_CONTEXT){ printf("ES 3.0 context also failed 0x%x\n", eglGetError()); return 1; }
        printf("ES 3.0 context: OK (fell back)\n");
    } else {
        printf("ES 3.1 context: OK\n");
    }
    (void)gotMinor;
    eglMakeCurrent(dpy,surf,surf,ctx);

    printf("GL_VERSION:  %s\n", glGetString(GL_VERSION));
    printf("GL_SL_VER:   %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    printf("GL_VENDOR:   %s\n", glGetString(GL_VENDOR));
    printf("----- MD5-gating caps -----\n");
    printf("MAX_VERTEX_SHADER_STORAGE_BLOCKS   = %d  (q2repro MD5 needs >= 2)\n", geti(GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS));
    printf("MAX_COMBINED_SHADER_STORAGE_BLOCKS = %d\n", geti(GL_MAX_COMBINED_SHADER_STORAGE_BLOCKS));
    printf("MAX_SHADER_STORAGE_BUFFER_BINDINGS = %d\n", geti(GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS));
    printf("MAX_SHADER_STORAGE_BLOCK_SIZE      = %d\n", geti(GL_MAX_SHADER_STORAGE_BLOCK_SIZE));
    printf("MAX_COMPUTE_SHADER_STORAGE_BLOCKS  = %d\n", geti(GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS));
#ifdef GL_MAX_TEXTURE_BUFFER_SIZE_EXT
    printf("MAX_TEXTURE_BUFFER_SIZE_EXT        = %d\n", geti(GL_MAX_TEXTURE_BUFFER_SIZE_EXT));
#else
    printf("MAX_TEXTURE_BUFFER_SIZE            = (token 0x8C2B) %d\n", geti(0x8C2B));
#endif
    const char *ext = (const char*)glGetString(GL_EXTENSIONS);
    printf("----- feature extensions -----\n");
    printf("GL_EXT/OES_texture_buffer: %s\n", (ext && strstr(ext,"texture_buffer"))?"PRESENT":"absent");
    printf("shader_storage / compute : %s\n", (ext && (strstr(ext,"shader_storage")||strstr(ext,"compute_shader")))?"PRESENT":"absent");
    printf("----- verdict -----\n");
    int md5 = (geti(GL_MAX_VERTEX_SHADER_STORAGE_BLOCKS) >= 2) || (ext && strstr(ext,"texture_buffer"));
    printf("ANGLE-Metal can run q2repro MD5 GPU skeletal: %s\n", md5?"YES":"NO");
    return 0;
}
