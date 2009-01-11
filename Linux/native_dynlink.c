/*
    LXLoader - Loads LX exe files or DLLs for execution or to extract information from.
    Copyright (C) 2007  Sven Ros�n (aka Viking)

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
    Or see <http://www.gnu.org/licenses/>
*/

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <modlx.h>
#include <loadobjlx.h>
#include <io.h>
#include <modmgr.h>

#ifndef __WATCOMC__
#include <dlfcn.h>
#endif
#ifdef __WATCOMC__
#include "ow_dlfcn.h"
#endif

#include <native_dynlink.h>

struct native_module_rec native_module_root; /* Root for module list.*/

//const int LOADING = 1;
//const int DONE_LOADING = 0;

/*char **mini_native_libpath;
 int sz_native_mini_libpath;*/
char *mini_native_libpath[]={"."};
int sz_native_mini_libpath=0; /* Number of elements in mini_libpath (zero-based).*/

const char *dll_suf = ".so";  /* DLL extension (native libs). */
const char *lib_pre = "lib";  /* lib prefix. lib<module name>.so*/
char *sep = "/";              /* Dir separator for GNU/Linux,  */

  /* Initializes the root node in the linked list, which itself is not used.
  Only to make sure the list at least always has one element allocated. */
void init_native_dynlink(void) {
        native_module_root.mod_name =  "root";
        native_module_root.file_name_path = "root";
        native_module_root.file_name = "root";
        native_module_root.module_struct = 0;
        native_module_root.next = 0;
}

#ifdef SDIOS
#include <ctype.h>
int strcasecmp(const char* dest, const char* src)
{
        while(*dest != 0 && toupper(*src) == toupper(*dest)) {
                dest++;
                src++;
        }

        return *dest - *src;
}
#endif

        /* Register a module with the name. */
struct native_module_rec *
native_register_module(char * name, char * filepath, void * mod_struct) {
        struct native_module_rec *new_mod;
        struct native_module_rec *prev;

        io_printf("register_module: %s, %p \n", name, mod_struct);
        new_mod = (struct native_module_rec *) malloc(sizeof(struct native_module_rec));
        new_mod->mod_name = (char *)malloc(strlen(name)+1);
        strcpy(new_mod->mod_name, name);
        prev = &native_module_root;

        while(prev->next) /* Find free node at end. */
                prev = (struct native_module_rec *) prev->next;

        prev->next = new_mod;  /*struct native_module_rec module_struct*/
        new_mod->module_struct = mod_struct; /* A pointer to handle for .so file. */

        new_mod->file_name_path = (char *)malloc(strlen(filepath)+1);
        strcpy(new_mod->file_name_path, filepath);

        return new_mod;
}

        /* Searches for the module name which the process proc needs.
           It first sees if it's already loaded and then just returns the found module.
           If it can't be found load_module() searches the mini_libpath inside find_module_path(). */
void * native_find_module(char * name) {
        struct native_module_rec * prev;
        void *ptr_mod;

        prev = (struct native_module_rec *) native_module_root.next;

        while(prev) {
                io_printf("find_module: %s == %s, mod=%p \n", name, prev->mod_name, prev->module_struct);
                if(strcmp(name, prev->mod_name)==0) {
                        io_printf("ret find_module: %p\n", prev->module_struct);

                        if(prev->load_status == LOADING) {
                                io_printf("find_module: ERROR, Cycle in loading of %s\n",name);
                                return 0;
                        }
                        return prev->module_struct;
                }
                prev = (struct native_module_rec *) prev->next;
        }

        ptr_mod = native_load_module(name);
        if(ptr_mod != 0) { /* If the module has been loaded, register it. */
                /* register_module(name, ptr_mod); */
                return ptr_mod;
        }

        return 0;
}


        /* Searches a module in the mini_libpath. */
unsigned long native_find_module_path(char * name, char * full_path_name) {

        /* /pub/projekt_src/os2start/libmsg.so */
        /*const char *mini_libpath[] = {
                "/pub/projekt_src/os2start",
                "/pub/L4_Fiasco/tudos2/tudos/l4/pkg/loader/server/src/test_os2start/mini_msg_dll",
                        "/mnt/rei3/OS2/os2_program/prog_iso/Mplayer_os2/mplayer",
                        "/mnt/rei3/OS2/os2_program/prog_iso/Mplayer_os2/libc-0.6.1-csd1",
                        }; */



        char * p_buf = full_path_name;
        int i =0;
        FILE *f=0;
        do {
                p_buf = full_path_name;
                p_buf[0] = 0;
                strcat(p_buf, mini_native_libpath[i]);
                strcat(p_buf, sep);
                strcat(p_buf, lib_pre);
                strcat(p_buf, name);
                strcat(p_buf, dll_suf);
                io_printf("native dynlink search: %s\n", p_buf);
                f = fopen(p_buf, "rb"); /* Tries to open the file, if it works f is a valid pointer.*/
                ++i;
        }while(!f && (i <= sz_native_mini_libpath));
        if(f)
                fclose(f);
        else
                p_buf[0] = 0;
        return 0;
}

        /* Loads a module name which proc needs. */
void * native_load_module(char * name) {

        const int buf_size = 4096;
        char buf[4096];
        char *p_buf = (char *) &buf;

        native_find_module_path(name, p_buf); /* Searches for module name and returns the full path in
                                                                        the buffer p_buf. */

        /*struct LX_module *lx_exe_mod = (struct LX_module *) malloc(sizeof(struct LX_module)); */
        io_printf("load_module: '%s' \n", p_buf);
        /*FILE *f = fopen(p_buf, "rb");  */
                                   /* Open file in read only binary mode, in case this code
                                          will be compiled on OS/2 or on windows. */

        /* Load LX file from buffer. */
        /* if(load_lx_stream((char*)lx_buf, pos, &lx_exe_mod)) { */


        /* Load LX file from ordinary disk file. */


        /* Load LX file from ordinary disk file. */
        if(p_buf ) {




                void *handle;
                struct native_module_rec *new_module_el;
                /*int (*mydltest)(const char *s);
                char *error; */

                handle = dlopen (p_buf, RTLD_LAZY);
                if (!handle) {
                        fprintf(stderr, "Could not open '%s': %s\n", p_buf, dlerror());
                        return handle;
                }
                new_module_el = native_register_module(name, p_buf, handle);
                new_module_el->load_status = LOADING;

                /*mydltest = dlsym(handle, "dltest");
                if ((error = dlerror()) != NULL)  {
                        fprintf(stderr, "Could not locate symbol 'dltest': %s\n", error);
                        //exit(1);
                } */



                new_module_el->load_status = DONE_LOADING;
                return handle;
        }

        io_printf("load_module: Load error!!! of %s in %s\n", name, p_buf);
        return 0;
}

struct native_module_rec * native_get_root() {
        return &native_module_root;
}

struct native_module_rec * native_get_next(struct native_module_rec * el) {
        if(el != 0)
                return (struct native_module_rec *) el->next;
        else
                return 0;
}

char * native_get_name(struct native_module_rec * el) {
        if(el != 0)
                return el->mod_name;
        else
                return 0;
}

struct LX_module * native_get_module(struct native_module_rec * el) {
        if(el != 0)
                return (struct LX_module *) el->module_struct;
        else
                return 0;
}

void native_print_module_table(void) {
        struct native_module_rec * el = native_get_root();
        io_printf("--- Native loaded Module Table ---\n");
        while((el = native_get_next(el))) {
                io_printf("module = %s, module_struct = %p, load_status = %d\n",
                                el->mod_name, el->module_struct, el->load_status);
        }
}



void * native_get_func_ptr_str_modname(char * funcname, char * modname) {
        void *mod_handle;
        void *mydltest;
        char *error;
        
        io_printf(" Searching func ptr '%s' in '%s' \n", funcname, modname);
        mod_handle = native_find_module(modname);
        mydltest = dlsym(mod_handle, funcname);
        if ((error = dlerror()) != (char *)0)  {
                fprintf(stderr, "Could not locate symbol 'dltest': %s\n", error);
                //exit(1);
        }
        return mydltest;
}

void * native_get_func_ptr_handle_modname(char * funcname, void * native_mod_handle) {
        char * error;
        void * mydltest = dlsym(native_mod_handle, funcname);
        if ((error = dlerror()) != (char *)0)  {
                fprintf(stderr, "Could not locate symbol 'dltest': %s\n", error);
                //exit(1);
        }
        io_printf("native_get_func_ptr_handle_modname( %s, %p)=%p\n",
                        funcname, native_mod_handle, mydltest);
        return mydltest;
}

void set_native_libpath(char ** path, int nr) {
  *mini_native_libpath = *path;
  sz_native_mini_libpath = nr;
}

char ** get_native_libpath() {
  return mini_native_libpath;
}
