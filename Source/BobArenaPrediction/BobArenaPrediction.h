#pragma once

#include "CoreMinimal.h"

// Все сетевые события прототипа пишутся в этот канал с тегами [DASH] / [CORRECTION] / [SERVER].
// Текст логов намеренно ASCII/English: лог UE читается в PowerShell без проблем с кириллицей.
DECLARE_LOG_CATEGORY_EXTERN(LogBobPrediction, Log, All);
