#include <assert.h>
#include <unistd.h>
#include <termios.h>
#include <signal.h>
#include <sys/wait.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include "../src/cli/terminal.h"
static void marker(int s){(void)s;}
int main(void) {
	unsigned char keys[]={'q','Q','D',3,4,17,'d',' '};
	for(unsigned i=0;i<sizeof(keys);i++) {
		int ready[2],master;assert(pipe(ready)==0);
		pid_t child=forkpty(&master,0,0,0);assert(child>=0);
		if(!child) {
			close(ready[0]);struct termios before,after;
			signal(SIGINT,marker);struct sigaction old,current;assert(sigaction(SIGINT,0,&old)==0);
			assert(tcgetattr(0,&before)==0);
			assert(terminal_start()==0);assert(terminal_start()==0);
			assert(write(ready[1],"r",1)==1);
			int key=-1;while(key<0)key=terminal_key();if(key!=keys[i])fprintf(stderr,"Key expected %u, got %d\n",keys[i],key);assert(key==keys[i]);
			assert(write(ready[1],"k",1)==1);
			terminal_stop();terminal_stop();
			assert(write(ready[1],"s",1)==1);
			int got=tcgetattr(0,&after);
			assert(got==0);
			/* macOS sets PENDIN when canonical input resumes. It is kernel
			 * bookkeeping for retyping pending input, not a changed setting. */
			assert((before.c_lflag&~PENDIN)==(after.c_lflag&~PENDIN) && before.c_iflag==after.c_iflag);
			assert(before.c_cc[VMIN]==after.c_cc[VMIN] && before.c_cc[VTIME]==after.c_cc[VTIME]);
			assert(write(ready[1],"t",1)==1);
			assert(sigaction(SIGINT,0,&current)==0 && old.sa_handler==current.sa_handler);
			assert(write(ready[1],"h",1)==1);
			_exit(0);
		}
		close(ready[1]);char r;assert(read(ready[0],&r,1)==1);
		assert(write(master,&keys[i],1)==1);int status;assert(waitpid(child,&status,0)==child);
		if(!WIFEXITED(status) || WEXITSTATUS(status)!=0) {
			fprintf(stderr,"PTY key %u failed (status=%d, signal=%d):\n",keys[i],status,WIFSIGNALED(status)?WTERMSIG(status):0);char message[1024];ssize_t n;
			while((n=read(ready[0],message,sizeof(message)))>0)fwrite(message,1,n,stderr);
			close(ready[0]);
			while((n=read(master,message,sizeof(message)))>0)fwrite(message,1,n,stderr);
			close(master);return 1;
		}
		close(ready[0]);
		/* Kitty keyboard flags 1|2|8 (disambiguate, event types, all keys as
		 * escapes) are pushed on start and popped exactly once on stop. */
		char out[4096];size_t used=0;ssize_t n;
		while(used<sizeof(out)-1 && (n=read(master,out+used,sizeof(out)-1-used))>0)used+=n;
		out[used]=0;
		char *push=strstr(out,"\033[>11u"),*pop=push?strstr(push,"\033[<u"):0;
		if(!push || !pop || strstr(pop+4,"\033[<u")) { fprintf(stderr,"PTY key %u: kitty push/pop missing or repeated\n",keys[i]);close(master);return 1; }
		close(master);
	}
	return 0;
}
