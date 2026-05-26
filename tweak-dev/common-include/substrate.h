#ifndef SUBSTRATE_H_
#define SUBSTRATE_H_
#include <objc/runtime.h>
#ifdef __cplusplus
extern "C" {
#endif
void MSHookMessageEx(Class _class, SEL message, IMP hook, IMP *old);
void MSHookFunction(void *symbol, void *hook, void **old);
#ifdef __cplusplus
}
#endif
#endif
