using UnrealBuildTool;
using System.Collections.Generic;

public class BobArenaPredictionTarget : TargetRules
{
	public BobArenaPredictionTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.Latest;
		IncludeOrderVersion = EngineIncludeOrderVersion.Latest;
		ExtraModuleNames.Add("BobArenaPrediction");
	}
}
