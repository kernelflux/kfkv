
#pragma once
#include "KFKVPredef.h"

KFKV_NAMESPACE_BEGIN

enum { UnKnown = 0, PowerMac = 1, Mac, iPhone, iPod, iPad, AppleTV, AppleWatch };

void GetAppleMachineInfo(int &device, int &version);

KFKV_NAMESPACE_END
