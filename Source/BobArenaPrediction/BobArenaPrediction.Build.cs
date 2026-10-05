using UnrealBuildTool;

public class BobArenaPrediction : ModuleRules
{
	public BobArenaPrediction(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
		PublicDependencyModuleNames.AddRange(new string[] { "Core", "CoreUObject", "Engine", "InputCore", "NetCore" });
	}
}
