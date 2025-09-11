import org.gradle.internal.jvm.Jvm
import java.net.URI

/**
 * =========================================================================
 * Git Pre-Push Hook Setup
 * =========================================================================
 *
 * This section contains a Gradle task to automate the setup of the pre-push hook.
 *
 * To use this task, copy and paste the `findAdoToken` method and the entire
 * `tasks.register("setupPrePushHook")` block into your project's `build.gradle.kts` file.
 *
 * --- INSTRUCTIONS ---
 *
 * 1. Open your project's `build.gradle.kts` file.
 *
 * 2. Copy the `findAdoToken` method and the `tasks.register` block below and
 * paste them anywhere outside of an existing task or method.
 *
 * 3. In the `tasks.register` block, find the `tagValue` variable and update the
 * string to match your project's ADO tag (e.g., "App:MyProjectTag").
 *
 * 4. Run the `setupPrePushHook` task from your IDE (either the Terminal or the Gradle tool window):
 * ./gradlew setupPrePushHook
 *
 * The `pre-push` hook will now be installed and configured in your `.git/hooks` directory.
 */
// The `File` and other types must be explicitly imported and typed.
fun findAdoToken(): String? {
    val configFiles = listOf(".zshrc", ".bash_profile", ".bashrc", ".profile")
    val homeDir = System.getProperty("user.home")

    for (fileName in configFiles) {
        val configFile = file("$homeDir/$fileName")
        if (configFile.exists() && configFile.canRead()) {
            val lines = configFile.readLines()
            for (line in lines) {
                // Kotlin's regex syntax is slightly different, but the logic remains the same.
                val regex = Regex("^\\s*(?:export\\s+)?ADO_TOKEN=['\"]?(.*?)['\"]?\\s*(?:#.*)?$")
                val matchResult = regex.find(line)
                if (matchResult != null) {
                    // Access the captured group using `groupValues`
                    return matchResult.groupValues[1]
                }
            }
        }
    }
    return null
}
tasks.register("setupPrePushHook") {
    // Property assignments use the `=` operator.
    group = "git"
    description = "Downloads and configures the pre-push hook for ADO."

    // Variable declarations use `val` (read-only) or `var` (mutable).
    val tagValue = "App:TODO"

    doLast {
        // Source URL for the pre-push hook script
        val scriptUrl = "https://raw.githubusercontent.com/schultzisaiah/GitMore/refs/heads/main/hooks/pre-push.py"

        // Determine the destination path for the hook
        val gitHooksDir = project.rootDir.resolve(".git/hooks")
        val hookFile = gitHooksDir.resolve("pre-push")
        val gitDir = project.rootDir.resolve(".git")

        // 1. Validate that this is a Git repository
        if (!gitDir.exists() || !gitDir.isDirectory) {
            println("❌ ERROR: This project does not appear to be a Git repository. Please initialize it first.")
            throw IllegalStateException("Not a Git repository.")
        }

        // 2. Ensure the hooks directory exists
        if (!gitHooksDir.exists()) {
            gitHooksDir.mkdirs()
        }

        // 3. Check for the ADO_TOKEN using the same logic as the Python script
        val adoToken = System.getenv("ADO_TOKEN") ?: findAdoToken()
        if (adoToken.isNullOrEmpty()) {
            println("⚠️  WARN: The 'ADO_TOKEN' environment variable is not set. The pre-push hook will not be able to interact with ADO.")
            println("ℹ️  Follow the instructions provided on the pre-push.py script to set this up.")
        }

        try {
            // 4. Download the script content from the remote URL
            println("🔎 Downloading the latest pre-push hook from $scriptUrl...")
            val scriptContent = URI(scriptUrl).toURL().readText(Charsets.UTF_8)

            // 5. Replace the TAG_VALUE placeholder with the configured value
            println("⚙️ Setting the TAG_VALUE to '$tagValue'...")
            val updatedContent = scriptContent.replace(
                "TAG_VALUE = \"App:TODO\"",
                "TAG_VALUE = \"$tagValue\""
            )

            // 6. Write the updated content to the hook file
            println("⚙️ Writing the hook file to ${hookFile.absolutePath}...")
            hookFile.writeText(updatedContent)

            // 7. Make the script executable
            hookFile.setExecutable(true)
            println("✅ Successfully installed and configured the pre-push hook.")

        } catch (e: Exception) {
            println("❌ An error occurred during hook setup: ${e.message}")
            throw e
        }

        // Dynamically match git-hook environment to JDK set in IDE
        val javaExecutable = Jvm.current().javaExecutable

        // The executable (e.g., 'java') is in the 'bin' directory of the JDK.
        // We navigate up two parent directories to get the root JDK path.
        val jdkHome = javaExecutable.parentFile.parentFile

        // Get a reference to the .jdk_path file in the project's root directory.
        val pathFile = project.rootDir.resolve(".jdk_path")

        // Write the absolute path of the JDK home to the file.
        pathFile.writeText(jdkHome.absolutePath)

        // Print a confirmation message to the console.
        println("✅ JDK path saved to .jdk_path: ${jdkHome.absolutePath}")
    }
}
