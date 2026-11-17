package me.zed_0xff.zombie_buddy;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/** Compile-only stub of ZombieBuddy's legacy @Patch (ZB 2.x remaps it to annotations.Patch at load). Not shipped. */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.TYPE)
public @interface Patch {
    String className();
    String methodName();
    boolean isAdvice() default true;

    @Retention(RetentionPolicy.RUNTIME) @Target(ElementType.METHOD)
    @interface OnEnter { boolean skipOn() default false; }

    @Retention(RetentionPolicy.RUNTIME) @Target(ElementType.METHOD)
    @interface OnExit {}

    @Retention(RetentionPolicy.RUNTIME) @Target(ElementType.PARAMETER)
    @interface This { boolean readOnly() default true; }

    @Retention(RetentionPolicy.RUNTIME) @Target(ElementType.PARAMETER)
    @interface Argument { int value() default 0; boolean readOnly() default true; }
}
