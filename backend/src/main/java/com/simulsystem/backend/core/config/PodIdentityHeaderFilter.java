package com.simulsystem.backend.core.config;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Adds the responding Kubernetes Pod name to API responses.
 * Enabled only in the Kubernetes profile so local/production behavior is unchanged.
 */
@Component
@Profile("k8s")
public class PodIdentityHeaderFilter extends OncePerRequestFilter {

    private static final String HEADER_NAME = "X-Served-By";

    @Override
    protected void doFilterInternal(
            HttpServletRequest request,
            HttpServletResponse response,
            FilterChain filterChain
    ) throws ServletException, IOException {
        if (request.getRequestURI().startsWith("/api/")) {
            String podName = System.getenv().getOrDefault("POD_NAME", "unknown");
            response.setHeader(HEADER_NAME, podName);
        }

        filterChain.doFilter(request, response);
    }
}
